defmodule Relay.Runs.Supervisor do
  @moduledoc """
  The runs engine's process tree: the run-id Registry, the
  DynamicSupervisor holding one `RunServer` per `:running` run, the
  card-event `Listener` (baton interplay — RLY-132), and a boot task that
  resumes — every `:running` run in Postgres restarts its server, which
  revokes any orphaned non-done job and re-dispatches the current node as
  a fresh attempt. `:parked` runs stay dormant — parking never holds a
  process (ADR 0006). `rest_for_one`: a Registry crash restarts everything
  that depends on it, including the Listener (whose reconciliation is
  stateless, so restarting it is safe).

  Every name is an option defaulting to the global atom the engine has always used, so the
  application starts exactly the tree it always did. A test starts its own tree under unique
  names and registers it with `Relay.Runs.Instance` (ADR 0009 rule 2); `:callers` re-seeds the
  caller chain this supervisor would otherwise sever, for its GenServer children explicitly and
  for the boot `Task` by inheritance (`Task` copies `$callers` from the process that spawns it —
  this supervisor).
  """

  use Supervisor

  alias Relay.Runs.ExecutorReaper
  alias Relay.Runs.Instance
  alias Relay.Runs.Listener

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    Instance.adopt_callers(opts)
    default = Instance.default()
    callers = Keyword.get(opts, :callers)

    children = [
      {Registry, keys: :unique, name: Keyword.get(opts, :registry, default.registry)},
      {DynamicSupervisor, name: Keyword.get(opts, :run_supervisor, default.run_supervisor), strategy: :one_for_one},
      {Listener, name: Keyword.get(opts, :listener, Listener), callers: callers},
      Supervisor.child_spec({Task, &Relay.Runs.resume_all/0}, id: :runs_boot_resume, restart: :temporary),
      {ExecutorReaper, name: Keyword.get(opts, :executor_reaper, ExecutorReaper), callers: callers}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
