defmodule Relay.EventsFirehoseTest do
  use ExUnit.Case, async: true

  alias Relay.Events

  test "broadcast/2 mirrors every event onto the global firehose with its board id" do
    :ok = Events.subscribe_firehose()
    :ok = Events.broadcast(123, {:stages_changed, 123})
    assert_receive {123, {:stages_changed, 123}}
  end

  test "board-topic subscribers are unaffected" do
    :ok = Events.subscribe(456)
    :ok = Events.broadcast(456, {:stages_changed, 456})
    assert_receive {:stages_changed, 456}
  end
end
