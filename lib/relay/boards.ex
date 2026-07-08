defmodule Relay.Boards do
  @moduledoc """
  The Boards context: boards and their stages (the workflow pipeline).
  Cards arrive in MMF 03 (`Relay.Cards`).
  """

  use Boundary, deps: [Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Events
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Stage
  alias Schemas.User

  @seed_stages [
    {"Backlog", :human, :unstarted},
    {"Spec", :human, :unstarted},
    {"Plan", :ai, :in_progress},
    {"Code", :ai, :in_progress},
    {"Review", :human, :in_progress},
    {"Deploy", :ai, :in_progress},
    {"Done", :human, :complete}
  ]

  @category_order [:unstarted, :in_progress, :complete]

  @doc """
  Returns the user's board with `stages` preloaded in `position` order,
  creating the board (unique slug derived from the user) and seeding the
  default 7-stage pipeline on first call. Idempotent per user.
  """
  def get_or_create_default_board(%User{} = user) do
    board = Repo.get_by(Board, owner_id: user.id) || create_default_board!(user)
    Repo.preload(board, stages: from(s in Stage, order_by: s.position))
  end

  @doc "Returns the board's stages in position order."
  def list_stages(%Board{id: board_id}) do
    Repo.all(from s in Stage, where: s.board_id == ^board_id, order_by: s.position)
  end

  @doc "Returns the stage with `id` on `board`, or nil (board-scoped lookup)."
  def get_stage(%Board{id: board_id}, id) do
    Repo.get_by(Stage, id: id, board_id: board_id)
  end

  @doc """
  Enables a `:review` or `:done` sub-lane on `parent` (a main stage),
  creating the child stage with the predictable owner (review → :human,
  done → the parent's owner). Idempotent — returns the existing child if
  the lane is already enabled.
  """
  def enable_lane(%Stage{lane: :main} = parent, lane) when lane in [:review, :done] do
    case get_sublane(parent, lane) do
      %Stage{} = existing ->
        {:ok, existing}

      nil ->
        %Stage{board_id: parent.board_id, parent_id: parent.id, lane: lane}
        |> Stage.changeset(%{
          name: "#{parent.name}:#{lane_word(lane)}",
          position: next_position(parent.board_id),
          category: parent.category,
          owner: lane_owner(lane, parent)
        })
        |> Repo.insert()
        |> broadcast_stages_changed(parent.board_id)
    end
  end

  @doc """
  Disables `parent`'s `lane` sub-lane. Returns `{:ok, :disabled}` when the
  (empty) child is removed, `{:ok, :not_enabled}` when there is nothing to
  remove, or `{:error, :not_empty}` when the lane still holds cards.
  """
  def disable_lane(%Stage{} = parent, lane) when lane in [:review, :done] do
    case get_sublane(parent, lane) do
      nil ->
        {:ok, :not_enabled}

      %Stage{} = child ->
        if Repo.exists?(from c in Card, where: c.stage_id == ^child.id) do
          {:error, :not_empty}
        else
          {:ok, _} = Repo.delete(child)
          broadcast_stages_changed({:ok, :disabled}, parent.board_id)
        end
    end
  end

  @doc "The stage's `:review`/`:done` children, ordered Review then Done."
  def sublanes(%Stage{} = parent) do
    Repo.all(
      from s in Stage,
        where: s.parent_id == ^parent.id,
        order_by: fragment("array_position(ARRAY['review','done'], ?)", s.lane)
    )
  end

  @doc """
  Updates a main stage's editable configuration (name, description, owner —
  and any future per-stage fields cast by `Schemas.Stage.changeset/2`;
  MMFs 11/13 reuse this). Broadcasts `{:stages_changed, board_id}` on
  success. `owner` is the stage's *meant-for* designation only — this never
  touches any card's `card_owners` rows.
  """
  def update_stage(%Stage{} = stage, attrs) do
    stage
    |> Stage.changeset(attrs)
    |> Repo.update()
    |> broadcast_stages_changed(stage.board_id)
  end

  @doc """
  Swaps `stage` with the adjacent main stage in board position order
  (`:up` = toward position 1), inside a transaction. Crossing into the
  neighbour's category makes the moved stage adopt it (the mockup: "cross
  into another category and it takes on that meaning"). At the board's
  edge it is a no-op: `{:ok, stage}`, no broadcast.
  """
  def reorder_stage(%Stage{lane: :main} = stage, direction) when direction in [:up, :down] do
    mains = main_stages(stage.board_id)
    index = Enum.find_index(mains, &(&1.id == stage.id))
    neighbor_index = if direction == :up, do: index - 1, else: index + 1

    case fetch_neighbor(mains, neighbor_index) do
      nil -> {:ok, stage}
      %Stage{} = neighbor -> swap_stages(stage, neighbor)
    end
  end

  @doc """
  Appends a new main stage (name "New stage", owner `:human`) at the end of
  `category` — an empty category appends right after every earlier
  category's stages. Broadcasts on success.
  """
  def create_stage(%Board{id: board_id}, category) when category in @category_order do
    {:ok, stage} =
      Repo.transaction(fn ->
        position = append_position(board_id, category)
        shift_positions_from(board_id, position)

        %Stage{board_id: board_id}
        |> Stage.changeset(%{name: "New stage", position: position, category: category, owner: :human})
        |> Repo.insert!()
      end)

    broadcast_stages_changed({:ok, stage}, board_id)
  end

  @doc """
  Deletes an empty main stage; its Review/Done children cascade via the
  `parent_id` FK (they are guaranteed empty by the guard). Returns
  `{:error, :not_empty}` when the stage or any of its sub-lanes holds
  cards, `{:error, :last_stage}` for the board's only main stage. Sub-lane
  children are never directly deletable (only via `disable_lane/2`).
  """
  def delete_stage(%Stage{lane: :main} = stage) do
    cond do
      length(main_stages(stage.board_id)) == 1 ->
        {:error, :last_stage}

      stage_holds_cards?(stage) ->
        {:error, :not_empty}

      true ->
        {:ok, deleted} = Repo.delete(stage)
        broadcast_stages_changed({:ok, deleted}, stage.board_id)
    end
  end

  @doc """
  The human-facing label for `stage`: its own `name` for a main-lane
  stage, or `"<parent name> · Review|Done"` for a sub-lane child (loading
  the parent). Guards the same composite-name leak (`enable_lane/2`
  builds the child's internal `name` as `"Code:Review"`) that the
  drawer's move menu already sanitizes — route any other display of a
  stage name (e.g. the `:moved` activity phrase) through this instead of
  the raw `Stage.name`.
  """
  def stage_display_name(%Stage{lane: :main} = stage), do: stage.name

  def stage_display_name(%Stage{parent_id: parent_id, lane: lane}) do
    parent = Repo.get!(Stage, parent_id)
    "#{parent.name} · #{lane_word(lane)}"
  end

  defp get_sublane(%Stage{} = parent, lane) do
    Repo.get_by(Stage, parent_id: parent.id, lane: lane)
  end

  @position_park_offset 1_000_000

  defp main_stages(board_id) do
    Repo.all(from s in Stage, where: s.board_id == ^board_id and s.lane == :main, order_by: s.position)
  end

  defp fetch_neighbor(_mains, index) when index < 0, do: nil
  defp fetch_neighbor(mains, index), do: Enum.at(mains, index)

  # stages_board_id_position_index is not deferrable, so a direct swap
  # would collide: park the moved stage on a free position first, so each
  # subsequent update lands on a just-vacated slot.
  defp swap_stages(%Stage{} = stage, %Stage{} = neighbor) do
    {:ok, moved} =
      Repo.transaction(fn ->
        parked = next_position(stage.board_id)

        stage |> Stage.changeset(%{position: parked}) |> Repo.update!()
        neighbor |> Stage.changeset(%{position: stage.position}) |> Repo.update!()

        stage
        |> Stage.changeset(%{position: neighbor.position, category: neighbor.category})
        |> Repo.update!()
      end)

    broadcast_stages_changed({:ok, moved}, moved.board_id)
  end

  # Position right after the category's last main stage; an empty category
  # appends after every earlier category's stages (or at 1 on an empty board).
  defp append_position(board_id, category) do
    allowed = Enum.take_while(@category_order, &(&1 != category)) ++ [category]

    last =
      board_id
      |> main_stages()
      |> Enum.filter(&(&1.category in allowed))
      |> List.last()

    if last, do: last.position + 1, else: 1
  end

  # Frees `position` by shifting every stage at or after it up by one — in
  # two passes (way out of range, then back down to original + 1) because
  # a single `position + 1` update can transiently collide on the unique
  # index depending on row order.
  defp shift_positions_from(board_id, position) do
    tail = from s in Stage, where: s.board_id == ^board_id and s.position >= ^position
    Repo.update_all(tail, inc: [position: @position_park_offset])

    parked = from s in Stage, where: s.board_id == ^board_id and s.position >= ^@position_park_offset
    Repo.update_all(parked, inc: [position: -(@position_park_offset - 1)])
  end

  defp stage_holds_cards?(%Stage{} = stage) do
    stage_ids = [stage.id | stage |> sublanes() |> Enum.map(& &1.id)]
    Repo.exists?(from c in Card, where: c.stage_id in ^stage_ids)
  end

  # MMF 18: stage config changed — coarse event, receivers refetch stages.
  defp broadcast_stages_changed({:ok, _value} = result, board_id) do
    Events.broadcast(board_id, {:stages_changed, board_id})
    result
  end

  defp broadcast_stages_changed({:error, _reason} = result, _board_id), do: result

  defp lane_owner(:review, _parent), do: :human
  defp lane_owner(:done, %Stage{owner: owner}), do: owner

  defp lane_word(:review), do: "Review"
  defp lane_word(:done), do: "Done"

  defp next_position(board_id) do
    (Repo.one(from s in Stage, where: s.board_id == ^board_id, select: max(s.position)) || 0) + 1
  end

  defp create_default_board!(user) do
    {:ok, board} =
      Repo.transaction(fn ->
        board =
          %Board{owner_id: user.id}
          |> Board.changeset(%{slug: unique_slug(user)})
          |> Repo.insert!()

        @seed_stages
        |> Enum.with_index(1)
        |> Enum.each(fn {{name, owner, category}, position} ->
          %Stage{board_id: board.id}
          |> Stage.changeset(%{name: name, position: position, category: category, owner: owner})
          |> Repo.insert!()
        end)

        board
      end)

    board
  end

  defp unique_slug(user) do
    base = slug_base(user)

    if slug_taken?(base), do: suffixed_slug(base, 2), else: base
  end

  defp suffixed_slug(base, n) do
    candidate = "#{base}-#{n}"

    if slug_taken?(candidate), do: suffixed_slug(base, n + 1), else: candidate
  end

  defp slug_taken?(slug), do: Repo.exists?(from(b in Board, where: b.slug == ^slug))

  defp slug_base(user) do
    source = user.name || user.email |> String.split("@") |> hd()

    case source |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") do
      "" -> "board"
      base -> base
    end
  end
end
