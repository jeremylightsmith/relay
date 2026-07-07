defmodule Relay.Cards do
  @moduledoc """
  The Cards context: cards on a board, per-board ref allocation
  (RLY-1, RLY-2, ...), and per-stage ordering.
  """

  use Boundary, deps: [Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Stage

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

  @doc """
  Updates a card's user-editable attributes (`:title`, `:description`,
  `:tag`), returning `{:ok, card}` or `{:error, changeset}`. The
  programmatic fields (`board_id`, `stage_id`, `position`, `ref_number`)
  are never cast and cannot be changed here.
  """
  def update_card(%Card{} = card, attrs) do
    card
    |> Card.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Sets the card's baton status (`:queued | :working | :needs_input |
  :in_review | :done`) and optional `progress` (0–100) from `attrs`,
  returning `{:ok, card}` (owners preloaded) or `{:error, changeset}`.
  Status only ever changes through this explicit call — never as a side
  effect of moving a card.
  """
  def set_status(%Card{} = card, attrs) do
    card
    |> Card.status_changeset(attrs)
    |> Repo.update()
    |> preload_owners_result()
  end

  @doc """
  Fetches the card a human-facing ref (e.g. `"RLY-12"`) points at on
  `board`, or `nil` when the ref does not parse against the board's key
  or no such card exists on that board. Scoping by `board_id` means a
  ref can never resolve to another board's card — this is the card
  drawer's authorization check.
  """
  def get_card_by_ref(%Board{} = board, ref) when is_binary(ref) do
    case parse_ref_number(board, ref) do
      {:ok, ref_number} -> Repo.get_by(Card, board_id: board.id, ref_number: ref_number)
      :error -> nil
    end
  end

  @doc """
  Moves `card` into `target_stage` at the 0-based `index` among the
  stage's cards (excluding the moved card itself), returning
  `{:ok, card}` or `{:error, changeset}`.

  The whole target stage is re-indexed inside a transaction so
  `position` stays contiguous (1..n) and deterministic; `index` is
  clamped into range. The target stage must belong to the card's board —
  callers resolve both on the current board, and a cross-board call
  raises `FunctionClauseError`. A cross-stage move fires the
  stage-change seam (`emit_stage_changed/2`), a no-op until MMF 07 hooks
  activity logging into it.
  """
  def move_card(%Card{board_id: board_id} = card, %Stage{board_id: board_id} = target_stage, index)
      when is_integer(index) do
    previous_stage_id = card.stage_id

    Repo.transaction(fn ->
      moved = place_at(card, target_stage, index)

      if moved.stage_id != previous_stage_id do
        emit_stage_changed(moved, previous_stage_id)
      end

      moved
    end)
  end

  defp parse_ref_number(%Board{key: key}, ref) do
    prefix = key <> "-"

    with true <- String.starts_with?(ref, prefix),
         {ref_number, ""} <- Integer.parse(String.replace_prefix(ref, prefix, "")),
         true <- ref_number > 0 do
      {:ok, ref_number}
    else
      _ -> :error
    end
  end

  # Re-indexes the target stage: its other cards keep their relative
  # order, `card` is inserted at the clamped index, and positions are
  # rewritten 1..n (updates are no-ops for cards whose row is unchanged).
  defp place_at(%Card{} = card, %Stage{} = target_stage, index) do
    others =
      Repo.all(
        from c in Card,
          where: c.stage_id == ^target_stage.id and c.id != ^card.id,
          order_by: [asc: c.position, asc: c.id]
      )

    index = index |> max(0) |> min(length(others))

    others
    |> List.insert_at(index, card)
    |> Enum.with_index(1)
    |> Enum.map(&reposition(&1, target_stage.id))
    |> Enum.find(&(&1.id == card.id))
  end

  defp reposition({%Card{} = card, position}, stage_id) do
    case Repo.update(Ecto.Changeset.change(card, stage_id: stage_id, position: position)) do
      {:ok, card} -> card
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # MMF 07 seam: activity logging ("moved" timeline entries) hooks in
  # here. Intentionally a no-op today — do not add behaviour in MMF 05.
  defp emit_stage_changed(%Card{} = _moved_card, _previous_stage_id), do: :ok

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

  defp preload_owners_result({:ok, card}), do: {:ok, preload_owners(card)}
  defp preload_owners_result({:error, changeset}), do: {:error, changeset}

  defp preload_owners(nil), do: nil
  defp preload_owners(card_or_cards), do: Repo.preload(card_or_cards, owners: :user)

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
