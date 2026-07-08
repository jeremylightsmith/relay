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
end
