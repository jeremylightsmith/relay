defmodule Relay.Cards do
  @moduledoc """
  The Cards context: cards on a board, per-board ref allocation
  (RLY-1, RLY-2, ...), and per-stage ordering.
  """

  use Boundary, deps: [Relay.Boards, Relay.Repo], exports: [Card]

  import Ecto.Query

  alias Relay.Boards.Board
  alias Relay.Boards.Stage
  alias Relay.Cards.Card
  alias Relay.Repo

  @doc """
  Creates a card in `stage` from user-supplied `attrs` (`:title`, optional
  `:tag`), returning `{:ok, card}` or `{:error, changeset}`.

  The next per-board `ref_number` is allocated by locking the board row
  (`SELECT ... FOR UPDATE`) and bumping `Board.card_seq` inside the
  transaction, so refs are sequential and gap-free even under concurrent
  creates. The card is appended to the bottom of the stage.
  """
  def create_card(%Stage{} = stage, attrs) do
    Repo.transaction(fn ->
      ref_number = allocate_ref_number(stage.board_id)

      case insert_card(stage, ref_number, attrs) do
        {:ok, card} -> card
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Returns all of `board`'s cards, ordered by stage then `position` — the
  render order within each stage column.
  """
  def list_cards(%Board{id: board_id}) do
    Repo.all(
      from c in Card,
        where: c.board_id == ^board_id,
        order_by: [asc: c.stage_id, asc: c.position, asc: c.id]
    )
  end

  @doc """
  The human-facing card ref: the board's key plus the card's per-board
  ref number, e.g. `"RLY-12"`.

  Takes the board explicitly (a refinement of the spec's sketched
  `Card.ref/1`) so callers that already hold the board don't need
  `card.board` preloaded.
  """
  def ref(%Board{key: key}, %Card{ref_number: ref_number}), do: "#{key}-#{ref_number}"

  # Locks the board row so concurrent creates serialize, then bumps
  # `card_seq` and returns the newly allocated ref number. A rollback of
  # the surrounding transaction also reverts the bump, keeping refs
  # gap-free.
  defp allocate_ref_number(board_id) do
    board = Repo.one!(from b in Board, where: b.id == ^board_id, lock: "FOR UPDATE")
    ref_number = board.card_seq + 1

    {1, _} =
      Repo.update_all(from(b in Board, where: b.id == ^board_id), set: [card_seq: ref_number])

    ref_number
  end

  defp insert_card(%Stage{} = stage, ref_number, attrs) do
    %Card{
      board_id: stage.board_id,
      stage_id: stage.id,
      position: next_position(stage),
      ref_number: ref_number
    }
    |> Card.changeset(attrs)
    |> Repo.insert()
  end

  # New cards append to the bottom of the stage. Safe under concurrency
  # because the caller already holds the board-row lock.
  defp next_position(%Stage{id: stage_id}) do
    (Repo.one(from c in Card, where: c.stage_id == ^stage_id, select: max(c.position)) || 0) + 1
  end
end
