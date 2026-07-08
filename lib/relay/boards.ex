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
    {"Plan", :ai, :planning},
    {"Code", :ai, :in_progress},
    {"Review", :human, :in_progress},
    {"Deploy", :ai, :in_progress},
    {"Done", :human, :complete}
  ]

  @category_order [:unstarted, :planning, :in_progress, :complete]

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
  Updates a main stage's editable configuration (name, description, owner,
  WIP limit — and the MMF 13 gate fields `approval_gate` /
  `reject_to_stage_id`). The reject target must be a main-lane stage on
  the same board (nil means "this stage"). Broadcasts
  `{:stages_changed, board_id}` on success. `owner` is the stage's
  *meant-for* designation only — this never touches any card's
  `card_owners` rows.
  """
  def update_stage(%Stage{} = stage, attrs) do
    stage
    |> Stage.changeset(attrs)
    |> validate_reject_target(stage.board_id)
    |> Repo.update()
    |> broadcast_stages_changed(stage.board_id)
  end

  @doc """
  The next main stage after `stage` in board order (position), or nil
  when `stage` is the board's last main stage. Sub-lane children are
  never "next" — MMF 13's approve routing advances through this.
  """
  def next_main_stage(%Stage{lane: :main} = stage) do
    stage.board_id
    |> main_stages()
    |> Enum.drop_while(&(&1.id != stage.id))
    |> Enum.at(1)
  end

  @doc """
  Moves `stage` one step up or down among the board's main stages (`:up` =
  toward position 1), inside a transaction. With a same-category neighbour
  in the move direction the two stages swap positions (categories are
  untouched). When the stage is already first/last in its category it
  crosses one-directionally into the adjacent category in `@category_order`
  — adopting that category even when it is empty, landing at its edge (top
  when moving down, bottom when moving up) — and no other stage's category
  or relative order changes. Already in the first category moving up (or
  the last moving down) it is a no-op: `{:ok, stage}`, no broadcast.
  """
  def reorder_stage(%Stage{lane: :main} = stage, direction) when direction in [:up, :down] do
    mains = main_stages(stage.board_id)
    index = Enum.find_index(mains, &(&1.id == stage.id))
    stage = Enum.at(mains, index)
    neighbor_index = if direction == :up, do: index - 1, else: index + 1
    neighbor = fetch_neighbor(mains, neighbor_index)

    if neighbor && neighbor.category == stage.category do
      mains
      |> List.replace_at(index, neighbor)
      |> List.replace_at(neighbor_index, stage)
      |> persist_order(stage, stage.category)
    else
      cross_category(mains, stage, direction)
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

  # MMF 13: a gate may only send rejects to a main-lane stage on its own
  # board. Validated here (not in the schema) because only the context
  # knows the board.
  defp validate_reject_target(changeset, board_id) do
    case Ecto.Changeset.get_change(changeset, :reject_to_stage_id) do
      nil ->
        changeset

      target_id ->
        if Repo.exists?(from s in Stage, where: s.id == ^target_id and s.board_id == ^board_id and s.lane == :main) do
          changeset
        else
          Ecto.Changeset.add_error(changeset, :reject_to_stage_id, "must be a main stage on the same board")
        end
    end
  end

  defp fetch_neighbor(_list, index) when index < 0, do: nil
  defp fetch_neighbor(list, index), do: Enum.at(list, index)

  # The stage is first/last in its category: it alone adopts the adjacent
  # category in @category_order (even an empty one — never skipping past
  # it). Because a category's stages are contiguous in position order,
  # landing at the adjacent category's near edge (top going down, bottom
  # going up) keeps the flat board order unchanged — only the moved
  # stage's category changes. No adjacent category -> silent no-op.
  defp cross_category(mains, stage, direction) do
    category_index = Enum.find_index(@category_order, &(&1 == stage.category))
    adjacent_index = if direction == :up, do: category_index - 1, else: category_index + 1

    case fetch_neighbor(@category_order, adjacent_index) do
      nil -> {:ok, stage}
      category -> persist_order(mains, stage, category)
    end
  end

  # Persists `ordered_mains` as the board's main-stage order, renumbering
  # positions 1..n and setting `category` on `moved` alone. The whole block
  # is parked out of range first so no renumbering step collides with the
  # stages_board_id_position_index unique index (sub-lane children always
  # sit above every main-stage position, so 1..n stays free and children
  # are untouched). Returns the broadcast-wrapped moved stage.
  defp persist_order(ordered_mains, %Stage{} = moved, category) do
    {:ok, updated} =
      Repo.transaction(fn ->
        ids = Enum.map(ordered_mains, & &1.id)
        parked = from s in Stage, where: s.id in ^ids
        Repo.update_all(parked, inc: [position: @position_park_offset])

        ordered_mains
        |> Enum.with_index(1)
        |> Enum.map(fn {stage, position} -> renumber!(stage, position, moved.id, category) end)
        |> Enum.find(&(&1.id == moved.id))
      end)

    broadcast_stages_changed({:ok, updated}, updated.board_id)
  end

  # `position` is force-changed: a stage's final position often equals its
  # stale in-memory one (cross-category moves keep the flat order), yet the
  # parked row still needs writing back to its real position.
  defp renumber!(stage, position, moved_id, category) do
    attrs = if stage.id == moved_id, do: %{category: category}, else: %{}

    stage
    |> Stage.changeset(attrs)
    |> Ecto.Changeset.force_change(:position, position)
    |> Repo.update!()
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
