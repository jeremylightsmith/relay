defmodule Relay.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Relay.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Runs.Capacity
  alias Relay.Runs.Instance

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Relay.DataCase
      import Relay.Factory

      alias Relay.Repo
    end
  end

  setup tags do
    Relay.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Relay.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc ~S"""
  Grants `pid` access to the calling test's sandbox connection and returns it, so it composes
  with `start_supervised!/1` (ADR 0009 rule 2):

      pruner = allow!(start_supervised!({Pruner, name: :"pruner_#{System.unique_integer([:positive])}"}))

  Use this whenever the test itself holds the pid of a process that touches the database. When a
  `DynamicSupervisor` severs the chain and the test never sees the pid, use `$callers`
  propagation instead (`Relay.Runs.Instance.adopt_callers/1`).

  Tolerates a process that is already an owner or already allowed, and the shared-mode case, so
  the call is safe in a module that is still `async: false`.
  """
  def allow!(pid) when is_pid(pid) do
    case Sandbox.allow(Relay.Repo, self(), pid) do
      :ok -> pid
      {:already, _owner_or_allowed} -> pid
      # Shared mode (`async: false`): the caller holds no checkout of its own, so there is
      # nothing to grant — every process in the VM already shares the owner's connection.
      :not_found -> pid
    end
  end

  @doc """
  Starts a `Relay.Runs.Capacity` owning this test's own ETS table and registers it on the calling
  process's `Relay.Runs.Instance`, so the test's advertised capacity is invisible to — and
  unwipeable by — every concurrent test (ADR 0009). Returns the table name.

  `start_engine!/1` already does this; call one or the other, never both (they share the
  `Relay.Runs.Capacity` supervised-child id).
  """
  def start_capacity! do
    n = System.unique_integer([:positive])
    table = :"relay_runs_capacity_#{n}"
    :ok = Instance.register(%{capacity_table: table})

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({Capacity, name: :"relay_runs_capacity_server_#{n}", table: table},
        id: Capacity
      )
    )

    table
  end

  @doc """
  Starts this test's own runs engine — Registry, run `DynamicSupervisor`, `Listener`,
  `ExecutorReaper`, boot-resume `Task` and a private capacity table — under unique names, and
  registers them on the calling process's `Relay.Runs.Instance`. Returns the instance.

  Replaces `start_supervised!(Relay.Runs.Supervisor)`, which started a globally-named tree and so
  could only ever exist once per VM (ADR 0009 rule 2). `callers: [self()]` re-seeds the chain the
  supervisor would sever, which is what gives every engine process the test's sandbox connection
  and its instance.

  Supervised under the child id `Relay.Runs.Supervisor`, so `stop_supervised!(Relay.Runs.Supervisor)`
  still stops it; use `restart_engine!/0` to bring it back under the same names.

  > #### The `Listener` is NOT isolated {: .warning}
  >
  > The names are per-instance; the event topic is not. `Relay.Runs.Listener` subscribes to the
  > process-global `Relay.Events.subscribe_firehose/0`, so the `Listener` this starts receives
  > **every concurrent test's** card events and reconciles them on *this* test's sandbox
  > connection. Harmless when a test's cards are its own (a foreign reconcile is a no-op), but a
  > test that asserts on *how many times* the engine reacted, or that stops the tree mid-flight,
  > will race. That is why `executor_reaper_test` and `board_settings_flow_preflight_test` are
  > `async: false`. See the "Known limitation" bullet in ADR 0009's Consequences.
  """
  def start_engine!(opts \\ []) do
    n = System.unique_integer([:positive])

    :ok =
      Instance.register(%{
        registry: :"relay_runs_registry_#{n}",
        run_supervisor: :"relay_runs_run_supervisor_#{n}"
      })

    _table = start_capacity!()
    start_engine_tree!(opts)
    Instance.current()
  end

  @doc """
  Stops and restarts this test's engine tree under the **same** registry, run-supervisor,
  listener, executor-reaper and capacity names — what a test that simulates an application
  restart needs (the boot-resume `Task` runs again against the same rows), and what a test that
  pinned a name via `start_engine!(listener: Listener)` needs the pin to survive.

  Tolerates the tree already being down (a test that needs a real down window — e.g. answering a
  card while nothing is listening — calls `stop_supervised!(Relay.Runs.Supervisor)` itself first,
  then this to bring it back), so it is safe whether or not a stop already ran.
  """
  def restart_engine!(opts \\ []) do
    case ExUnit.Callbacks.stop_supervised(Relay.Runs.Supervisor) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    start_engine_tree!(opts)
    Instance.current()
  end

  # Names are stashed in the calling process's dictionary (not `Relay.Runs.Instance` — this is a
  # `DataCase`-only stability contract, not part of "which engine tree do I belong to") so a bare
  # `restart_engine!()` reuses the exact names `start_engine!/1` picked, instead of rolling fresh
  # random ones that orphan any `Process.whereis(pinned_name)` the test relies on.
  @engine_opts_key :relay_data_case_engine_opts

  defp start_engine_tree!(opts) do
    instance = Instance.current()
    n = System.unique_integer([:positive])

    defaults = [
      name: :"relay_runs_supervisor_#{n}",
      registry: instance.registry,
      run_supervisor: instance.run_supervisor,
      listener: :"relay_runs_listener_#{n}",
      executor_reaper: :"relay_runs_executor_reaper_#{n}",
      callers: [self()]
    ]

    resolved = Keyword.merge(Process.get(@engine_opts_key, defaults), opts)
    Process.put(@engine_opts_key, resolved)

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({Relay.Runs.Supervisor, resolved}, id: Relay.Runs.Supervisor)
    )
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
