defmodule Relay.Events do
  @moduledoc """
  The realtime notification seam (MMF 18): board-scoped Phoenix.PubSub
  topics carrying semantic domain events from the contexts to every open
  `RelayWeb.BoardLive` (and any future subscriber).

  Topic: `"board:<board_id>"`. Event vocabulary — broadcast by the
  contexts after each successful mutation, never by controllers or
  LiveViews, so the LiveView and REST API entry points share one path:

    * `{:card_upserted, card}` — create or any in-place edit
      (title/description/tag, status, owners); `card` arrives with
      owners preloaded.
    * `{:card_moved, card, from_stage_id}` — cross- or within-stage move.
    * `{:card_archived, card}` — a card was archived (soft-hidden); receivers
      drop it from its column and close its drawer. Restore reuses
      `{:card_upserted, card}`.
    * `{:timeline_appended, card_id, entry}` — a new `Schemas.Comment` or
      `Schemas.Activity` entry (with `:user` preloaded).
    * `{:card_log_appended, card_id, entries}` — a batch of runner log rows
      (`Schemas.Activity`, `:user` nil, chronological ascending) was persisted onto a
      card by `Relay.Activity.LogSink` (RLY-112). Deliberately **one event per card per
      flush**, not one per entry: `broadcast/2` bumps the board version every call, so a
      per-entry event would bump once per log line — a write storm under exactly the load
      the sink exists to absorb.
    * `{:stages_changed, board_id}` — any stage/config change; coarse on
      purpose, receivers refetch stages.
    * `{:board_updated, board}` — a board's editable attributes (currently
      just `name`) changed; carries the fresh board (stages not preloaded).

  A global firehose topic (`events:firehose`) additionally carries every
  event as `{board_id, event}` — one subscription observes all boards
  (RLY-132: `Relay.Runs.Listener` reconciles card events against runs).

  Broadcasting is fire-and-forget: `broadcast/2` swallows PubSub errors
  and always returns `:ok`, so a broadcast failure can never fail the
  mutation that triggered it.
  """

  use Boundary, deps: [Relay.BoardWatch]

  @pubsub Relay.PubSub
  @firehose "events:firehose"

  @doc "Subscribes the calling process to `board_id`'s event topic."
  def subscribe(board_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(board_id))
  end

  @doc """
  Subscribes the calling process to the global firehose: every event from
  every board, as `{board_id, event}`.
  """
  def subscribe_firehose do
    Phoenix.PubSub.subscribe(@pubsub, @firehose)
  end

  @doc """
  Broadcasts `event` to every subscriber of `board_id`'s topic and bumps the
  board's version (RLY-12). Fire-and-forget: PubSub and version-bump errors are
  swallowed and `:ok` is always returned, so neither can fail the mutation that
  triggered it.
  """
  def broadcast(board_id, event) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic(board_id), event)
    _ = Phoenix.PubSub.broadcast(@pubsub, @firehose, {board_id, event})
    _ = bump_version(board_id)
    :ok
  end

  defp bump_version(board_id) do
    Relay.BoardWatch.bump(board_id)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp topic(board_id), do: "board:#{board_id}"
end
