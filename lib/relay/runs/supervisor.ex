defmodule Relay.Runs.Supervisor do
  @moduledoc """
  The runs engine's process tree: the run-id Registry, the
  DynamicSupervisor holding one `RunServer` per `:running` run, and a boot
  task that resumes — every `:running` run in Postgres restarts its
  server, which revokes any orphaned non-done job and re-dispatches the
  current node as a fresh attempt. `:parked` runs stay dormant — parking
  never holds a process (ADR 0006). `rest_for_one`: a Registry crash
  restarts everything that depends on it.
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Relay.Runs.Registry},
      {DynamicSupervisor, name: Relay.Runs.RunSupervisor, strategy: :one_for_one},
      Supervisor.child_spec({Task, &Relay.Runs.resume_all/0}, id: :runs_boot_resume, restart: :temporary)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
