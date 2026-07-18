defmodule Relay.AgentLog do
  @moduledoc """
  The ephemeral agent-log seam (RLY-55): a *stateless* broadcast context that
  mirrors the board runner's feed to any open `RelayWeb.BoardLive` bottom sheet.

  There is deliberately **no** server-side buffer or GenServer. `record/2` stamps
  each entry with a server-assigned `id`/`ts` and broadcasts it on the per-board
  logs topic `"board:<id>:logs"`. A `Phoenix.PubSub.broadcast` to a topic with zero
  subscribers is a no-op, so when nobody has the sheet open the messages evaporate
  and cost no memory. A `BoardLive` subscribes only while its sheet is open and
  accumulates lines in its own socket stream — the socket process is the only
  memory. `Relay.Activity` remains the durable audit log.

  Entry broadcast as `{:agent_log, entry}`:
    * `id`   — `System.unique_integer([:monotonic, :positive])`, the stream dom_id and ordering key.
    * `ts`   — `DateTime` assigned on receipt; rendered `HH:MM:SS`.
    * `ref`  — the card ref the line belongs to (may be `nil` for board-level lines).
    * `kind` — `:lifecycle | :claude | :error`; drives line color.
    * `text` — the message.

  RLY-112: `record/2` additionally hands the **ref-tagged** entries to
  `Relay.Activity.LogSink`, which persists them onto their card. This broadcast is
  deliberately unchanged (Q7→A) — the per-board sheet keeps its ephemeral feed, and
  ref-less board-level lines stay broadcast-only, never persisted. Each stamped entry
  also carries `run_id` — the AI session that emitted the line, captured from day one
  though nothing renders it yet — and, alongside it, `node_job_id` (RLY-134): the
  node-job that emitted the line.
  """

  use Boundary, deps: [Relay.Activity]

  alias Relay.Activity.LogSink

  @pubsub Relay.PubSub

  @kinds %{"lifecycle" => :lifecycle, "claude" => :claude, "error" => :error}

  @doc "Subscribes the calling process to `board_id`'s logs topic."
  def subscribe(board_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(board_id))

  @doc "Unsubscribes the calling process from `board_id`'s logs topic."
  def unsubscribe(board_id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(board_id))

  @doc "The per-board logs topic."
  def topic(board_id), do: "board:#{board_id}:logs"

  @doc """
  Stamps each raw entry in `entries` with a server-assigned `id`/`ts`, broadcasts it
  as `{:agent_log, entry}` on `topic(board_id)`, and hands the ref-tagged ones to
  `Relay.Activity.LogSink` for persistence. Fire-and-forget: always returns `:ok`.
  Each raw entry is a string-keyed map with `"ref"` (optional), `"kind"`, `"text"`,
  `"run_id"` (optional), and `"node_job_id"` (optional).
  """
  def record(board_id, entries) when is_list(entries) do
    stamped = Enum.map(entries, &stamp/1)

    Enum.each(stamped, fn entry ->
      Phoenix.PubSub.broadcast(@pubsub, topic(board_id), {:agent_log, entry})
    end)

    LogSink.enqueue(board_id, Enum.filter(stamped, & &1.ref))
  end

  defp stamp(entry) do
    %{
      id: System.unique_integer([:monotonic, :positive]),
      ts: DateTime.utc_now(),
      ref: blank_to_nil(Map.get(entry, "ref")),
      kind: Map.get(@kinds, Map.get(entry, "kind"), :lifecycle),
      text: to_string(Map.get(entry, "text", "")),
      run_id: blank_to_nil(Map.get(entry, "run_id")),
      node_job_id: blank_to_nil(Map.get(entry, "node_job_id"))
    }
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: to_string(v)
end
