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
  """

  use Boundary, deps: []

  @pubsub Relay.PubSub

  @kinds %{"lifecycle" => :lifecycle, "claude" => :claude, "error" => :error}

  @doc "Subscribes the calling process to `board_id`'s logs topic."
  def subscribe(board_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(board_id))

  @doc "Unsubscribes the calling process from `board_id`'s logs topic."
  def unsubscribe(board_id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(board_id))

  @doc "The per-board logs topic."
  def topic(board_id), do: "board:#{board_id}:logs"

  @doc """
  Stamps each raw entry in `entries` with a server-assigned `id`/`ts` and
  broadcasts it as `{:agent_log, entry}` on `topic(board_id)`. Fire-and-forget:
  always returns `:ok`. Each raw entry is a string-keyed map with `"ref"`
  (optional), `"kind"`, and `"text"`.
  """
  def record(board_id, entries) when is_list(entries) do
    Enum.each(entries, fn entry ->
      Phoenix.PubSub.broadcast(@pubsub, topic(board_id), {:agent_log, stamp(entry)})
    end)
  end

  defp stamp(entry) do
    %{
      id: System.unique_integer([:monotonic, :positive]),
      ts: DateTime.utc_now(),
      ref: blank_to_nil(Map.get(entry, "ref")),
      kind: Map.get(@kinds, Map.get(entry, "kind"), :lifecycle),
      text: to_string(Map.get(entry, "text", ""))
    }
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: to_string(v)
end
