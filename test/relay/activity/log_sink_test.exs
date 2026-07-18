defmodule Relay.Activity.LogSinkTest do
  use Relay.DataCase, async: false

  import Ecto.Query

  alias Relay.Activity
  alias Relay.Activity.LogSink

  # card_factory derives board_id FROM the stage — never pass `board:` to it.
  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    card = insert(:card, stage: stage, ref_number: 7)
    sink = start_supervised!({LogSink, name: :"log_sink_#{System.unique_integer([:positive])}", debounce_ms: 0})
    {:ok, board: board, card: card, sink: sink}
  end

  defp entry(attrs) do
    Map.merge(
      %{
        id: System.unique_integer([:monotonic, :positive]),
        ts: DateTime.utc_now(),
        ref: "RLY-7",
        kind: :claude,
        text: "a line",
        run_id: nil,
        node_job_id: nil
      },
      attrs
    )
  end

  # Drive one debounce window to completion: the cast, then the :flush it armed.
  defp settle(sink) do
    :sys.get_state(sink)
    send(sink, :flush)
    :sys.get_state(sink)
    :ok
  end

  defp rows(card), do: Repo.all(from a in Schemas.Activity, where: a.card_id == ^card.id, order_by: [asc: a.id])

  test "three casts in one window become one insert_all", %{board: board, card: card, sink: sink} do
    :ok = LogSink.enqueue(board.id, [entry(%{text: "one"})], sink)
    :ok = LogSink.enqueue(board.id, [entry(%{text: "two"})], sink)
    :ok = LogSink.enqueue(board.id, [entry(%{text: "three"})], sink)
    :ok = settle(sink)

    assert Enum.map(rows(card), & &1.text) == ["one", "two", "three"]
  end

  test "chronological order survives the debounce", %{board: board, card: card, sink: sink} do
    base = DateTime.from_naive!(~N[2026-07-01 10:00:00], "Etc/UTC")

    for i <- 1..5 do
      :ok = LogSink.enqueue(board.id, [entry(%{text: "line #{i}", ts: DateTime.add(base, i, :second)})], sink)
    end

    :ok = settle(sink)

    # Ascending id IS insert order, and inserted_at carries the stamped ts, not flush time.
    assert Enum.map(rows(card), & &1.text) == ["line 1", "line 2", "line 3", "line 4", "line 5"]
    assert Enum.map(rows(card), & &1.inserted_at) == for(i <- 1..5, do: DateTime.add(base, i, :second))
  end

  test "a 500-row burst flushes without waiting for the timer", %{board: board, card: card} do
    # debounce_ms is deliberately huge: only the @max_buffer bound can flush this.
    # `id:` override needed: the setup block already started a LogSink child under
    # the default (module-derived) id, and a plain Supervisor tracks children by id.
    sink = start_supervised!({LogSink, name: :log_sink_burst, debounce_ms: 60_000}, id: :log_sink_burst)

    :ok = LogSink.enqueue(board.id, for(i <- 1..500, do: entry(%{text: "burst #{i}"})), sink)
    :sys.get_state(sink)

    assert length(rows(card)) == 500
  end

  test "an unknown ref is dropped without crashing the sink", %{board: board, card: card, sink: sink} do
    :ok = LogSink.enqueue(board.id, [entry(%{ref: "RLY-9999", text: "ghost"})], sink)
    :ok = LogSink.enqueue(board.id, [entry(%{text: "real"})], sink)
    :ok = settle(sink)

    assert Process.alive?(sink)
    assert Enum.map(rows(card), & &1.text) == ["real"]
  end

  test "kind error maps to :failure; lifecycle and claude map to :action", %{board: board, card: card, sink: sink} do
    :ok = LogSink.enqueue(board.id, [entry(%{kind: :error, text: "boom"})], sink)
    :ok = LogSink.enqueue(board.id, [entry(%{kind: :lifecycle, text: "starting"})], sink)
    :ok = LogSink.enqueue(board.id, [entry(%{kind: :claude, text: "thinking"})], sink)
    :ok = settle(sink)

    assert Enum.map(rows(card), &{&1.text, &1.type}) == [
             {"boom", :failure},
             {"starting", :action},
             {"thinking", :action}
           ]

    assert Activity.kind(hd(rows(card))) == :failure
  end

  test "text, run_id and the agent actor land on the row", %{board: board, card: card, sink: sink} do
    :ok = LogSink.enqueue(board.id, [entry(%{text: "🔧 Edit lib/relay/cards.ex", run_id: "run-abc"})], sink)
    :ok = settle(sink)

    assert [row] = rows(card)
    assert row.text == "🔧 Edit lib/relay/cards.ex"
    assert row.run_id == "run-abc"
    assert row.actor_type == :agent
    assert row.user_id == nil
    assert row.meta == %{}
  end

  test "one card_log_appended event carries the whole flush", %{board: board, card: card, sink: sink} do
    Relay.Events.subscribe(board.id)

    :ok = LogSink.enqueue(board.id, [entry(%{text: "one"}), entry(%{text: "two"})], sink)
    :ok = settle(sink)

    assert_receive {:card_log_appended, card_id, entries}
    assert card_id == card.id
    assert Enum.map(entries, & &1.text) == ["one", "two"]
    # Never one bump per line — that is the write storm this event exists to avoid.
    refute_receive {:card_log_appended, _, _}
    # And never the per-entry timeline event.
    refute_receive {:timeline_appended, _, _}
  end

  test "entries for a card on another board are not written", %{sink: sink} do
    other_board = insert(:board)
    :ok = LogSink.enqueue(other_board.id, [entry(%{ref: "RLY-7", text: "cross-board"})], sink)
    :ok = settle(sink)

    assert Repo.aggregate(from(a in Schemas.Activity, where: a.text == "cross-board"), :count) == 0
  end
end
