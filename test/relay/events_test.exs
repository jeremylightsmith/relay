defmodule Relay.EventsTest do
  use Relay.DataCase, async: true

  import ExUnit.CaptureLog

  alias Relay.Events
  alias Relay.Repo

  test "subscribe/1 then broadcast/2 delivers the event to the subscriber" do
    board_id = System.unique_integer([:positive])

    assert :ok = Events.subscribe(board_id)
    assert :ok = Events.broadcast(board_id, {:stages_changed, board_id})

    assert_receive {:stages_changed, ^board_id}
  end

  test "an event for one board is not delivered to another board's subscriber" do
    board_id = System.unique_integer([:positive])
    other_board_id = System.unique_integer([:positive])

    assert :ok = Events.subscribe(board_id)
    assert :ok = Events.broadcast(other_board_id, {:stages_changed, other_board_id})

    refute_receive {:stages_changed, _board_id}, 100
  end

  test "broadcast/2 with no subscribers still returns :ok (fire-and-forget)" do
    assert :ok = Events.broadcast(System.unique_integer([:positive]), {:card_upserted, nil})
  end

  test "broadcast/2 bumps the board's version" do
    board_id = System.unique_integer([:positive])
    # Seed the counter first: the very first bump for a board starts from
    # System.os_time(:second), not 0, so we prime it before asserting a +1 step.
    Relay.BoardWatch.bump(board_id)
    before = Relay.BoardWatch.version(board_id)

    assert :ok = Events.broadcast(board_id, {:stages_changed, board_id})

    assert Relay.BoardWatch.version(board_id) == before + 1
  end

  test "a broadcast for one board doesn't move another board's version" do
    a = System.unique_integer([:positive])
    b = System.unique_integer([:positive])
    vb = Relay.BoardWatch.version(b)

    assert :ok = Events.broadcast(a, {:stages_changed, a})

    assert Relay.BoardWatch.version(b) == vb
  end

  test "a bump failure never breaks broadcast/2 (fire-and-forget)" do
    board_id = System.unique_integer([:positive])
    # Corrupt this board's counter row so update_counter raises (element 2 is
    # not an integer); broadcast/2 must swallow it and still return :ok.
    :ets.insert(:board_versions, {board_id, "not-an-integer"})

    assert :ok = Events.broadcast(board_id, {:stages_changed, board_id})
  end

  describe "after-commit delivery (RE386)" do
    setup do
      b = System.unique_integer([:positive])
      :ok = Events.subscribe(b)
      %{b: b}
    end

    test "a broadcast inside Repo.transaction/1 is held until the transaction commits", %{b: b} do
      assert {:ok, _} =
               Repo.transaction(fn ->
                 :ok = Events.broadcast(b, {:stages_changed, b})
                 refute_received {:stages_changed, ^b}
               end)

      assert_received {:stages_changed, ^b}
    end

    test "the firehose copy is held until commit and delivered exactly once", %{b: b} do
      :ok = Events.subscribe_firehose()

      assert {:ok, _} =
               Repo.transaction(fn ->
                 :ok = Events.broadcast(b, {:stages_changed, b})
                 refute_received {^b, {:stages_changed, ^b}}
               end)

      assert_received {^b, {:stages_changed, ^b}}
      refute_received {^b, {:stages_changed, ^b}}
    end

    test "the board version is bumped only after commit", %{b: b} do
      Relay.BoardWatch.bump(b)
      v = Relay.BoardWatch.version(b)

      assert {:ok, _} =
               Repo.transaction(fn ->
                 :ok = Events.broadcast(b, {:stages_changed, b})
                 assert Relay.BoardWatch.version(b) == v
               end)

      assert Relay.BoardWatch.version(b) == v + 1
    end

    test "nested transactions flush once, in enqueue order, when the outermost commits", %{b: b} do
      assert {:ok, _} =
               Repo.transaction(fn ->
                 :ok = Events.broadcast(b, {:board_updated, 1})

                 assert {:ok, _} =
                          Repo.transaction(fn -> :ok = Events.broadcast(b, {:board_updated, 2}) end)

                 refute_received {:board_updated, _}
                 :ok = Events.broadcast(b, {:board_updated, 3})
                 refute_received {:board_updated, _}
               end)

      assert_received {:board_updated, n1}
      assert_received {:board_updated, n2}
      assert_received {:board_updated, n3}
      assert [n1, n2, n3] == [1, 2, 3]
      refute_received {:board_updated, _}
    end

    test "Repo.rollback/1 drops the queued events", %{b: b} do
      assert {:error, :nope} =
               Repo.transaction(fn ->
                 :ok = Events.broadcast(b, {:stages_changed, b})
                 Repo.rollback(:nope)
               end)

      refute_receive {:stages_changed, _}, 100
    end

    test "a raise drops the queued events and resets the queue", %{b: b} do
      assert_raise RuntimeError, "boom", fn ->
        Repo.transaction(fn ->
          :ok = Events.broadcast(b, {:stages_changed, b})
          raise "boom"
        end)
      end

      refute_receive {:stages_changed, _}, 100

      :ok = Events.broadcast(b, {:stages_changed, b})
      assert_received {:stages_changed, ^b}
    end

    test "an Ecto.Multi delivers on success and drops on a failed step", %{b: b} do
      ok_multi =
        Ecto.Multi.run(Ecto.Multi.new(), :x, fn _repo, _ ->
          :ok = Events.broadcast(b, {:stages_changed, b})
          {:ok, 1}
        end)

      assert {:ok, %{x: 1}} = Repo.transaction(ok_multi)
      assert_received {:stages_changed, ^b}
      refute_received {:stages_changed, ^b}

      bad_multi =
        Ecto.Multi.run(Ecto.Multi.new(), :x, fn _repo, _ ->
          :ok = Events.broadcast(b, {:stages_changed, b})
          {:error, :bad}
        end)

      assert {:error, :x, :bad, %{}} = Repo.transaction(bad_multi)
      refute_receive {:stages_changed, _}, 100
    end

    test "Repo.transact/1 delivers on {:ok, _} and drops on {:error, _}", %{b: b} do
      assert {:ok, :done} =
               Repo.transact(fn ->
                 :ok = Events.broadcast(b, {:stages_changed, b})
                 refute_received {:stages_changed, ^b}
                 {:ok, :done}
               end)

      assert_received {:stages_changed, ^b}

      assert {:error, :no} =
               Repo.transact(fn ->
                 :ok = Events.broadcast(b, {:stages_changed, b})
                 {:error, :no}
               end)

      refute_receive {:stages_changed, _}, 100
    end

    test "outside a transaction a broadcast is delivered immediately", %{b: b} do
      :ok = Events.broadcast(b, {:stages_changed, b})
      assert_received {:stages_changed, ^b}
    end

    test "a raising after-commit callback is logged and the rest still run", %{b: b} do
      log =
        capture_log(fn ->
          assert {:ok, _} =
                   Repo.transaction(fn ->
                     :ok = Repo.after_commit(fn -> raise "cb boom" end)
                     :ok = Events.broadcast(b, {:stages_changed, b})
                   end)
        end)

      assert log =~ "cb boom"
      assert_received {:stages_changed, ^b}
    end

    test "after_commit/1 outside a transaction runs the callback now" do
      test_pid = self()
      assert :ok = Repo.after_commit(fn -> send(test_pid, :ran) end)
      assert_received :ran
    end
  end
end
