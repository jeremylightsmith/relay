defmodule Hamaca.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Boundary, top_level?: true, deps: [Hamaca, HamacaWeb]
  use Application

  alias Hamaca.Runs.SchedulerSupervisor

  @impl true
  def start(_type, _args) do
    children =
      [
        HamacaWeb.Telemetry,
        Hamaca.Repo,
        {DNSCluster, query: Application.get_env(:hamaca, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Hamaca.PubSub},
        # RE257 — story-map presence (roster + cursor topics). Requires Phoenix.PubSub above.
        # Touches no database, so it is safe to start in every environment including test.
        Hamaca.Presence,
        HamacaWeb.ApiLog,
        Hamaca.BoardWatch,
        # RLY-133: server-side dispatch. Capacity store (fed by the runner heartbeat), the per-board
        # scheduler registry + dynamic supervisor, and a boot task that starts a scheduler per
        # board only when :runs_auto_start is on (off in test, so boot never queries the DB).
        # RE298 / ADR 0009: the engine-instance lookup (Hamaca.Runs.Instance). A plain Registry
        # keyed by owner pid — empty in production, where every resolution falls through to the
        # default instance. Touches no database, so it is safe in every environment.
        {Registry, keys: :unique, name: Hamaca.Runs.InstanceRegistry},
        Hamaca.Runs.Capacity,
        {Registry, keys: :unique, name: Hamaca.Runs.SchedulerRegistry},
        SchedulerSupervisor,
        Supervisor.child_spec({Task, &SchedulerSupervisor.start_all/0},
          id: :runs_scheduler_boot,
          restart: :transient
        ),
        # RLY-112: debounces ref-tagged runner log lines into one insert_all per burst.
        Hamaca.Activity.LogSink,
        # RLY-112: ages :action chatter out after 14 days. Its first sweep is one
        # interval away, so booting never touches the DB.
        Hamaca.Activity.Pruner,
        # RE460: the hourly billing clock (resolves unknown answers, charges renewals, retries,
        # sends the billing emails). Only ticks when billing is on — never in test or on a self-hosted install.
        {Hamaca.Billing.Clock, enabled: Hamaca.Billing.enabled?()},
        # Push dispatch runs off the caller's process so a status change never waits
        # on (or fails because of) Apple (RLY-81).
        {Task.Supervisor, name: Hamaca.Push.TaskSupervisor},
        # Billing emails run off the billing clock's process, so a tick never waits on (or fails
        # because of) the mail provider (RE464).
        {Task.Supervisor, name: Hamaca.Billing.TaskSupervisor},
        # APNs requires HTTP/2. Req's shared default Finch pool is HTTP/1-first, so
        # push gets its own h2 pool (RLY-81).
        {Finch, name: Hamaca.Push.APNSFinch, pools: %{default: [protocols: [:http2], count: 1]}}
      ] ++
        usage_children() ++
        runs_children() ++
        [
          # Start to serve requests, typically the last entry
          HamacaWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hamaca.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # RE475: the usage tracker — the only writer of `usage_visits`; flushes once a minute when
  # something changed, and on shutdown. Off in test: a test starts its own and points
  # `:usage_tracker` at it, so no flush ever lands outside the sandbox.
  defp usage_children do
    if Application.get_env(:hamaca, :usage_tracking, true), do: [Hamaca.Usage.Tracker], else: []
  end

  # RLY-132: the runs engine — run-id Registry, one RunServer per :running
  # run, and the boot resume task. Off in test: tests start_supervised!
  # their own copy so processes are cleaned between tests and DB access
  # stays inside the sandbox.
  defp runs_children do
    if Application.get_env(:hamaca, :start_runs_supervisor, true), do: [Hamaca.Runs.Supervisor], else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HamacaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
