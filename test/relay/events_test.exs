defmodule Relay.EventsTest do
  use ExUnit.Case, async: true

  alias Relay.Events

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
end
