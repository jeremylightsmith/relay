defmodule Relay.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Boundary, top_level?: true, deps: [Relay, RelayWeb]
  use Application

  alias Relay.Runs.SchedulerSupervisor

  @impl true
  def start(_type, _args) do
    children =
      [
        RelayWeb.Telemetry,
        Relay.Repo,
        {DNSCluster, query: Application.get_env(:relay, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Relay.PubSub},
        RelayWeb.ApiLog,
        Relay.BoardWatch,
        # RLY-133: server-side dispatch. Capacity store (empty until W9), the per-board
        # scheduler registry + dynamic supervisor, and a boot task that starts a scheduler per
        # board only when :runs_auto_start is on (off in test, so boot never queries the DB).
        Relay.Runs.Capacity,
        {Registry, keys: :unique, name: Relay.Runs.SchedulerRegistry},
        SchedulerSupervisor,
        Supervisor.child_spec({Task, &SchedulerSupervisor.start_all/0},
          id: :runs_scheduler_boot,
          restart: :transient
        ),
        # RLY-112: debounces ref-tagged runner log lines into one insert_all per burst.
        Relay.Activity.LogSink,
        # RLY-112: ages :action chatter out after 14 days. Its first sweep is one
        # interval away, so booting never touches the DB.
        Relay.Activity.Pruner,
        # Push dispatch runs off the caller's process so a status change never waits
        # on (or fails because of) Apple (RLY-81).
        {Task.Supervisor, name: Relay.Push.TaskSupervisor},
        # APNs requires HTTP/2. Req's shared default Finch pool is HTTP/1-first, so
        # push gets its own h2 pool (RLY-81).
        {Finch, name: Relay.Push.APNSFinch, pools: %{default: [protocols: [:http2], count: 1]}}
      ] ++
        runs_children() ++
        [
          # Start to serve requests, typically the last entry
          RelayWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Relay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # RLY-132: the runs engine — run-id Registry, one RunServer per :running
  # run, and the boot resume task. Off in test: tests start_supervised!
  # their own copy so processes are cleaned between tests and DB access
  # stays inside the sandbox.
  defp runs_children do
    if Application.get_env(:relay, :start_runs_supervisor, true), do: [Relay.Runs.Supervisor], else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RelayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
