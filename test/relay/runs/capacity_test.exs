defmodule Relay.Runs.CapacityTest do
  # Uses the application-started Relay.Runs.Capacity instance, isolated by unique executor ids
  # (the RunnerPresence/BoardWatch test pattern).
  use ExUnit.Case, async: true

  alias Relay.Runs.Capacity

  defp executor_id, do: System.unique_integer([:positive])

  test "put/2 then snapshot/0 round-trips normalized free slots" do
    eid = executor_id()
    :ok = Capacity.put(eid, %{shared_clean: 2, exclusive: 1})

    assert %{shared_clean: 2, exclusive: 1} = Capacity.snapshot()[eid]
  end

  test "put/2 defaults missing classes to 0 and floors negatives" do
    eid = executor_id()
    :ok = Capacity.put(eid, %{shared_clean: 3})

    assert %{shared_clean: 3, exclusive: 0} = Capacity.snapshot()[eid]
  end

  test "clear/1 removes an executor" do
    eid = executor_id()
    :ok = Capacity.put(eid, %{shared_clean: 1, exclusive: 0})
    :ok = Capacity.clear(eid)

    refute Map.has_key?(Capacity.snapshot(), eid)
  end

  test "put/2 and clear/1 broadcast {:executor_capacity_changed, executor_id}" do
    eid = executor_id()
    :ok = Capacity.subscribe()

    :ok = Capacity.put(eid, %{shared_clean: 1, exclusive: 0})
    assert_receive {:executor_capacity_changed, ^eid}

    :ok = Capacity.clear(eid)
    assert_receive {:executor_capacity_changed, ^eid}
  end
end
