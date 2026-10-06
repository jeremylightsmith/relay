defmodule Relay.Runs.CapacityTest do
  # Uses the application-started Relay.Runs.Capacity instance, isolated by unique runner ids
  # (the BoardWatch test pattern), except the "instance scoping" describe block below, which
  # starts its own private capacity table via Relay.DataCase.start_capacity!/0 (ADR 0009).
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.Runs.Capacity

  defp runner_id, do: System.unique_integer([:positive])
  defp board_id, do: System.unique_integer([:positive])

  test "put/3 then snapshot/0 round-trips normalized free slots" do
    eid = runner_id()
    :ok = Capacity.put(eid, board_id(), %{shared_clean: 2, exclusive: 1})

    assert %{shared_clean: 2, exclusive: 1} = Capacity.snapshot()[eid]
  end

  test "put/3 defaults missing classes to 0 and floors negatives" do
    eid = runner_id()
    :ok = Capacity.put(eid, board_id(), %{shared_clean: 3})

    assert %{shared_clean: 3, exclusive: 0} = Capacity.snapshot()[eid]
  end

  test "clear/1 removes a runner" do
    eid = runner_id()
    :ok = Capacity.put(eid, board_id(), %{shared_clean: 1, exclusive: 0})
    :ok = Capacity.clear(eid)

    refute Map.has_key?(Capacity.snapshot(), eid)
  end

  test "put/3 and clear/1 broadcast {:runner_capacity_changed, runner_id}" do
    eid = runner_id()
    :ok = Capacity.subscribe()

    :ok = Capacity.put(eid, board_id(), %{shared_clean: 1, exclusive: 0})
    assert_receive {:runner_capacity_changed, ^eid}

    :ok = Capacity.clear(eid)
    assert_receive {:runner_capacity_changed, ^eid}
  end

  # Every runner heartbeat re-advertises its configured total, and every board's scheduler
  # subscribes to this global topic — so an unconditional broadcast woke EVERY board's
  # scheduler on every beat of every runner, exhausting the Repo pool in prod.
  test "put/2 does not broadcast when the runner's slots are unchanged" do
    eid = runner_id()
    :ok = Capacity.put(eid, %{shared_clean: 1, exclusive: 0})
    :ok = Capacity.subscribe()

    :ok = Capacity.put(eid, %{"shared_clean" => 1, "exclusive" => 0})
    refute_receive {:runner_capacity_changed, ^eid}

    :ok = Capacity.put(eid, %{shared_clean: 2, exclusive: 0})
    assert_receive {:runner_capacity_changed, ^eid}
  end

  test "clear/1 does not broadcast for a runner with no advertised slots" do
    eid = runner_id()
    :ok = Capacity.subscribe()

    :ok = Capacity.clear(eid)
    refute_receive {:runner_capacity_changed, ^eid}
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

    test "put/3 accepts a raw string-keyed client map" do
      eid = runner_id()
      :ok = Capacity.put(eid, board_id(), %{"gpu" => 1, "shared_clean" => "lots", "exclusive" => 2})

      assert Capacity.snapshot()[eid] == %{shared_clean: 0, exclusive: 2}
    end
  end

  describe "board-scoped entries and change-only broadcast (RE402)" do
    test "snapshot/0 carries only the slots, never the board id" do
      r = runner_id()
      :ok = Capacity.put(r, board_id(), %{shared_clean: 2, exclusive: 1})

      assert Capacity.snapshot()[r] == %{shared_clean: 2, exclusive: 1}
    end

    test "re-advertising the same slots is silent; a real change broadcasts" do
      {r, b} = {runner_id(), board_id()}
      :ok = Capacity.put(r, b, %{shared_clean: 1, exclusive: 0})
      :ok = Capacity.subscribe()

      :ok = Capacity.put(r, b, %{"shared_clean" => 1, "exclusive" => 0})
      refute_receive {:runner_capacity_changed, ^r}

      :ok = Capacity.put(r, b, %{shared_clean: 2, exclusive: 0})
      assert_receive {:runner_capacity_changed, ^r}
    end

    test "the same slots on a different board is a change" do
      {r, b1, b2} = {runner_id(), board_id(), board_id()}
      :ok = Capacity.put(r, b1, %{shared_clean: 1, exclusive: 0})
      :ok = Capacity.subscribe()

      :ok = Capacity.put(r, b2, %{shared_clean: 1, exclusive: 0})

      assert_receive {:runner_capacity_changed, ^r}
      assert Capacity.live?(b2)
      refute Capacity.live?(b1)
    end

    test "clear/1 of an absent runner is silent" do
      r = runner_id()
      :ok = Capacity.subscribe()

      :ok = Capacity.clear(r)

      refute_receive {:runner_capacity_changed, ^r}
    end

    test "clear/1 of a present runner removes it and broadcasts" do
      r = runner_id()
      :ok = Capacity.put(r, board_id(), %{shared_clean: 1, exclusive: 0})
      :ok = Capacity.subscribe()

      :ok = Capacity.clear(r)

      assert_receive {:runner_capacity_changed, ^r}
      refute Map.has_key?(Capacity.snapshot(), r)
    end

    test "live?/1 is false for all-zero slots and true once any class is positive" do
      b = board_id()
      :ok = Capacity.put(runner_id(), b, %{shared_clean: 0, exclusive: 0})
      refute Capacity.live?(b)

      :ok = Capacity.put(runner_id(), b, %{shared_clean: 0, exclusive: 1})
      assert Capacity.live?(b) == true
    end

    test "another board's slots never make a board live" do
      :ok = Capacity.put(runner_id(), board_id(), %{shared_clean: 1, exclusive: 0})

      assert Capacity.live?(board_id()) == false
    end

    test "live?/1 reads ETS only — zero Repo queries" do
      start_capacity!()
      parent = self()
      handler_id = {__MODULE__, :live_queries, parent}

      :telemetry.attach(
        handler_id,
        [:relay, :repo, :query],
        fn _event, _measurements, _meta, ^parent ->
          if self() == parent, do: send(parent, :repo_query)
        end,
        parent
      )

      try do
        assert Capacity.live?(board_id()) == false
        refute_received :repo_query
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "reaper eviction (RE402)" do
    setup do
      start_capacity!()
      %{board: insert(:board)}
    end

    defp stale!(runner) do
      Repo.update_all(from(r in Schemas.Runner, where: r.id == ^runner.id),
        set: [last_heartbeat: DateTime.truncate(DateTime.add(DateTime.utc_now(), -1000, :second), :second)]
      )
    end

    test "a stale runner's entry is evicted by the reclaim sweep", %{board: board} do
      runner = insert(:runner, board: board)
      stale!(runner)
      :ok = Capacity.put(runner.id, board.id, %{shared_clean: 1, exclusive: 0})
      assert Capacity.live?(board.id)

      :ok = Runs.reclaim_stale_runners()

      refute Map.has_key?(Capacity.snapshot(), runner.id)
      assert Capacity.live?(board.id) == false
    end

    test "a fresh runner's entry survives the sweep", %{board: board} do
      runner = insert(:runner, board: board)
      :ok = Capacity.put(runner.id, board.id, %{shared_clean: 1, exclusive: 0})

      :ok = Runs.reclaim_stale_runners()

      assert Capacity.snapshot()[runner.id] == %{shared_clean: 1, exclusive: 0}
      assert Capacity.live?(board.id) == true
    end

    test "the sweep is silent when a stale runner has no entry", %{board: board} do
      board |> then(&insert(:runner, board: &1)) |> stale!()
      :ok = Capacity.subscribe()

      :ok = Runs.reclaim_stale_runners()

      # `topic/0` is global, so concurrent async tests' broadcasts land here too. The sweep only
      # sees this sandbox's runners, so "silent" means no broadcast for any of them.
      sandbox_ids = Schemas.Runner |> Repo.all() |> MapSet.new(& &1.id)
      Process.sleep(100)
      assert Enum.filter(drain_capacity_changes([]), &MapSet.member?(sandbox_ids, &1)) == []
    end
  end

  defp drain_capacity_changes(acc) do
    receive do
      {:runner_capacity_changed, id} -> drain_capacity_changes([id | acc])
    after
      0 -> acc
    end
  end

  describe "instance scoping (ADR 0009)" do
    test "a test's own capacity table is invisible to the default instance" do
      eid = System.unique_integer([:positive])
      table = start_capacity!()

      :ok = Capacity.put(eid, board_id(), %{shared_clean: 1, exclusive: 0})

      assert %{shared_clean: 1} = Capacity.snapshot()[eid]
      assert table != Capacity.default_table()

      refute :ets.member(Capacity.default_table(), eid)
    end

    test "reset/0 no longer exists — a global wipe is not reachable from a test" do
      Code.ensure_loaded!(Capacity)
      refute function_exported?(Capacity, :reset, 0)
    end
  end
end
