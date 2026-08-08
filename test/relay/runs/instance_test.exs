defmodule Relay.Runs.InstanceTest do
  use ExUnit.Case, async: true

  alias Relay.Runs.FakeDispatcher
  alias Relay.Runs.Instance
  alias Relay.Runs.InstanceRegistry
  alias Relay.Runs.NoopDispatcher
  alias Relay.Runs.RunSupervisor

  describe "current/0 with nothing registered — the production path" do
    test "is byte-for-byte the default instance" do
      assert Instance.current() == Instance.default()
    end

    test "names exactly the global atoms the engine used before the indirection" do
      assert %{
               registry: Relay.Runs.Registry,
               run_supervisor: RunSupervisor,
               capacity_table: :runs_capacity,
               dispatcher: NoopDispatcher,
               dispatcher_pid: nil
             } = Instance.default()
    end
  end

  describe "register/1" do
    test "overrides only the given keys for the calling process" do
      :ok = Instance.register(%{registry: :my_registry})

      assert %{registry: :my_registry, run_supervisor: RunSupervisor} = Instance.current()
    end

    test "merges across calls rather than replacing" do
      :ok = Instance.register(%{registry: :my_registry})
      :ok = Instance.register(%{dispatcher: NoopDispatcher, dispatcher_pid: self()})

      assert %{registry: :my_registry, dispatcher_pid: pid} = Instance.current()
      assert pid == self()
    end

    test "a sibling process without $callers still sees the default" do
      :ok = Instance.register(%{registry: :my_registry})
      test_pid = self()

      spawn(fn -> send(test_pid, {:resolved, Instance.current()}) end)

      assert_receive {:resolved, resolved}
      assert resolved == Instance.default()
    end
  end

  describe "callers/0 and adopt_callers/1" do
    test "callers/0 leads with self()" do
      assert [pid | _rest] = Instance.callers()
      assert pid == self()
    end

    test "adopt_callers/1 is a no-op without the option" do
      before = Process.get(:"$callers")
      assert :ok = Instance.adopt_callers(run_id: 1)
      assert Process.get(:"$callers") == before
    end

    test "a process that adopts the chain resolves the registrant's instance" do
      :ok = Instance.register(%{registry: :my_registry})
      callers = Instance.callers()
      test_pid = self()

      spawn(fn ->
        :ok = Instance.adopt_callers(callers: callers)
        send(test_pid, {:resolved, Instance.current()})
      end)

      assert_receive {:resolved, %{registry: :my_registry}}
    end
  end

  describe "the engine's production wiring" do
    # The whole risk of this refactor is that the indirection stops resolving to the atoms the
    # application actually starts. Pin them against the supervisor's own defaults.
    test "Supervisor's defaults are the default instance's names" do
      default = Instance.default()

      assert default.registry == Relay.Runs.Registry
      assert default.run_supervisor == RunSupervisor
      assert default.capacity_table == Relay.Runs.Capacity.default_table()
    end

    test "InstanceRegistry is started by the application" do
      assert is_pid(Process.whereis(InstanceRegistry))
    end
  end

  describe "an instance-scoped dispatcher" do
    test "FakeDispatcher.register/1 resolves the registered dispatcher and its notification pid" do
      :ok = FakeDispatcher.register(self())

      assert Relay.Runs.dispatcher() == FakeDispatcher
      assert Instance.current().dispatcher_pid == self()
    end

    test "FakeDispatcher.register/1 does not leak through application env to a sibling process" do
      :ok = FakeDispatcher.register(self())
      test_pid = self()

      spawn(fn -> send(test_pid, {:dispatcher, Relay.Runs.dispatcher()}) end)

      assert_receive {:dispatcher, NoopDispatcher}
    end

    test "a process that has not registered still resolves the application's dispatcher" do
      test_pid = self()
      spawn(fn -> send(test_pid, {:dispatcher, Relay.Runs.dispatcher()}) end)

      assert_receive {:dispatcher, NoopDispatcher}
    end
  end
end
