defmodule Relay.Cards do
  @moduledoc """
  The Cards context: cards on a board and per-board ref allocation
  (RLY-1, RLY-2, ...).
  """

  use Boundary, deps: [Relay.Boards], exports: [Card]

  alias Relay.Boards.Board
  alias Relay.Cards.Card

  @doc """
  The human-facing card ref: the board's key plus the card's per-board
  ref number, e.g. `"RLY-12"`.

  Takes the board explicitly (a refinement of the spec's sketched
  `Card.ref/1`) so callers that already hold the board don't need
  `card.board` preloaded.
  """
  def ref(%Board{key: key}, %Card{ref_number: ref_number}), do: "#{key}-#{ref_number}"
end
