defmodule Relay.AgentLogTest do
  use ExUnit.Case, async: true

  alias Relay.AgentLog

  test "record/2 broadcasts one stamped entry per raw entry to subscribers" do
    board_id = System.unique_integer([:positive])
    assert :ok = AgentLog.subscribe(board_id)

    assert :ok =
             AgentLog.record(board_id, [
               %{"ref" => "RLY-7", "kind" => "claude", "text" => "hello"}
             ])

    assert_receive {:agent_log, entry}
    assert entry.ref == "RLY-7"
    assert entry.kind == :claude
    assert entry.text == "hello"
    assert is_integer(entry.id)
    assert %DateTime{} = entry.ts
  end

  test "record/2 defaults a missing/unknown kind to :lifecycle and a blank ref to nil" do
    board_id = System.unique_integer([:positive])
    assert :ok = AgentLog.subscribe(board_id)

    assert :ok = AgentLog.record(board_id, [%{"text" => "board level", "kind" => "bogus"}])

    assert_receive {:agent_log, entry}
    assert entry.kind == :lifecycle
    assert entry.ref == nil
  end

  test "record/2 with no subscribers still returns :ok (fire-and-forget)" do
    assert :ok = AgentLog.record(System.unique_integer([:positive]), [%{"text" => "x"}])
  end

  test "a log for one board is not delivered to another board's subscriber" do
    board_id = System.unique_integer([:positive])
    other = System.unique_integer([:positive])
    assert :ok = AgentLog.subscribe(board_id)

    assert :ok = AgentLog.record(other, [%{"text" => "elsewhere"}])

    refute_receive {:agent_log, _entry}, 100
  end

  test "unsubscribe/1 stops further delivery" do
    board_id = System.unique_integer([:positive])
    assert :ok = AgentLog.subscribe(board_id)
    assert :ok = AgentLog.unsubscribe(board_id)

    assert :ok = AgentLog.record(board_id, [%{"text" => "after unsub"}])

    refute_receive {:agent_log, _entry}, 100
  end
end
