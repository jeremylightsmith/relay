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

  describe "normalize/1 (RLY-201: the single capacity normalizer)" do
    test "accepts string keys from a JSON beat" do
      assert Capacity.normalize(%{"shared_clean" => 2, "exclusive" => 1}) ==
               %{shared_clean: 2, exclusive: 1}
    end

    test "accepts atom keys from in-process callers" do
      assert Capacity.normalize(%{shared_clean: 2, exclusive: 1}) ==
               %{shared_clean: 2, exclusive: 1}
    end

    test "drops an unknown isolation class instead of raising" do
      assert Capacity.normalize(%{"gpu" => 1, "shared_clean" => 2}) ==
               %{shared_clean: 2, exclusive: 0}
    end

    test "an unknown key never becomes an atom" do
      # The bug: String.to_existing_atom/1 on client data raised ArgumentError → 500.
      assert Capacity.normalize(%{"definitely_not_an_atom_rly201" => 1}) ==
               %{shared_clean: 0, exclusive: 0}
    end

    test "zeroes non-integer, negative, and nil values" do
      assert Capacity.normalize(%{"shared_clean" => "lots", "exclusive" => 2}) ==
               %{shared_clean: 0, exclusive: 2}

      assert Capacity.normalize(%{"shared_clean" => -3, "exclusive" => 1.5}) ==
               %{shared_clean: 0, exclusive: 0}

      assert Capacity.normalize(%{"shared_clean" => nil}) ==
               %{shared_clean: 0, exclusive: 0}
    end

    test "a missing class defaults to 0" do
      assert Capacity.normalize(%{"shared_clean" => 3}) == %{shared_clean: 3, exclusive: 0}
    end

    test "non-map input degrades to an all-zero map" do
      for input <- [nil, [], "capacity", 7, {:shared_clean, 1}] do
        assert Capacity.normalize(input) == %{shared_clean: 0, exclusive: 0}
      end
    end

    test "put/2 accepts a raw string-keyed client map" do
      eid = executor_id()
      :ok = Capacity.put(eid, %{"gpu" => 1, "shared_clean" => "lots", "exclusive" => 2})

      assert Capacity.snapshot()[eid] == %{shared_clean: 0, exclusive: 2}
    end
  end
end
