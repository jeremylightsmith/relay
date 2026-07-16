defmodule Relay.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Boundary, top_level?: true, deps: [Relay, RelayWeb]
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RelayWeb.Telemetry,
      Relay.Repo,
      {DNSCluster, query: Application.get_env(:relay, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Relay.PubSub},
      RelayWeb.ApiLog,
      Relay.BoardWatch,
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
      {Finch, name: Relay.Push.APNSFinch, pools: %{default: [protocols: [:http2], count: 1]}},
      # Start to serve requests, typically the last entry
      RelayWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Relay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RelayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
