defmodule Relay.StoryMap do
  @moduledoc """
  The StoryMap context (RE265): the board's **second lens**, orthogonal to stages.
  Activities and their Tasks form the backbone across the top, Releases are the swimlanes
  down the left, and real board cards fill the cells — story-map cards ARE board cards, not a
  separate entity.

  Three board-scoped structures (`Schemas.StoryActivity`, `Schemas.StoryTask`,
  `Schemas.Release`), each ordered by `position` ascending with ties broken by `id`. Cards
  carry three nilable FKs and start fully **UNMAPPED**.

  **The card→cell invariant** — if `story_task_id` is set, `story_activity_id` is set and
  equals that task's activity — is enforced by *derivation*, not by trusting the caller:
  `assign_card/2` looks the task up board-scoped and takes the activity from it, ignoring any
  activity passed alongside; `update_task/2` closes the other half — moving a task to another
  activity drags its mapped cards' `story_activity_id` along in the same transaction.
  `Schemas.Card.story_map_changeset/2` rejects the half-state on
  the direct-changeset path. `release_id` is genuinely independent: a card can be mapped to a
  cell with no release, and the artboard's "an activity with no release renders in the last
  lane" is a *display* rule owned by the story-map view (RE264), never a stored default.

  **Two independent orderings (RE262).** `cards.position` orders a card within its stage
  column; `cards.story_map_position` orders it within its story-map **cell**. They never touch
  each other — `assign_card/2` rewrites only the latter, `Cards.move_card/3` only the former.
  `story_map_position` is nullable and unbackfilled on purpose: nil means "nobody has ordered
  this card on the map yet", and the display sort (ascending, nils last) makes that total
  rather than an edge case.

  **Realtime.** Every structure write broadcasts `{:story_map_changed, board_id}` — coarse on
  purpose, mirroring `{:stages_changed, board_id}`; receivers refetch the structure. Card
  assignment emits no new event: it reuses `{:card_upserted, card}` through
  `Relay.Cards.notify_upserted/1`, so the card arrives with `owners`/`sub_tasks` preloaded
  exactly as that contract requires.

  **Seeding.** The three seeded swimlanes are `Schemas.Release.seed_names/0` — the one
  definition. `Relay.Boards.create_board/2` inserts them inside its own transaction
  (`Relay.Boards` must not depend on this context: `StoryMap -> Cards -> Boards` already
  exists, so the reverse edge would be a boundary cycle). The
  `backfill_story_map_releases` migration carries the one deliberate frozen copy of that list.
  """

  use Boundary, deps: [Relay.Cards, Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Ecto.Changeset
  alias Relay.Cards
  alias Relay.Events
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Release
  alias Schemas.StoryActivity
  alias Schemas.StoryTask

  @doc "The board's activities in `position` order. Takes a board or a board id."
  def list_activities(board) do
    id = board_id(board)

    Repo.all(from a in StoryActivity, where: a.board_id == ^id, order_by: [asc: a.position, asc: a.id])
  end

  @doc "All of the board's tasks, ordered by `(story_activity_id, position)`."
  def list_tasks(board) do
    id = board_id(board)

    Repo.all(
      from t in StoryTask,
        where: t.board_id == ^id,
        order_by: [asc: t.story_activity_id, asc: t.position, asc: t.id]
    )
  end

  @doc "The board's releases (swimlanes) in `position` order."
  def list_releases(board) do
    id = board_id(board)

    Repo.all(from r in Release, where: r.board_id == ^id, order_by: [asc: r.position, asc: r.id])
  end

  @doc """
  The `position` a newly appended activity, task or release takes: one past the highest in
  `list`, or 1 when the list is empty. Ties are harmless — no structure has a unique index on
  `position` and every read breaks ties by `id`.

  Pure and query-free: it is called with lists the caller has already loaded (for a task, with
  **that activity's** tasks only). `create_activity/2`, `create_task/2` and `create_release/2`
  all *require* `position`, so this is the one definition of "goes at the end" — no call site
  re-types `max + 1`.
  """
  def next_position(list), do: Enum.reduce(list, 0, &max(&1.position, &2)) + 1

  @doc "Creates an activity on `board`. `board_id` comes from the board, never from `attrs`."
  def create_activity(board, attrs) do
    id = board_id(board)

    %StoryActivity{board_id: id}
    |> StoryActivity.changeset(attrs)
    |> Repo.insert()
    |> broadcast_changed(id)
  end

  @doc "Renames/repositions an activity."
  def update_activity(%StoryActivity{} = activity, attrs) do
    activity
    |> StoryActivity.changeset(attrs)
    |> Repo.update()
    |> broadcast_changed(activity.board_id)
  end

  @doc """
  Deletes an activity. The database cascade deletes its tasks and **unmaps** every card that
  pointed at either — `release_id` is untouched.
  """
  def delete_activity(%StoryActivity{} = activity) do
    activity
    |> Repo.delete()
    |> broadcast_changed(activity.board_id)
  end

  @doc "Rewrites the given activities' `position` to `1..n`; ids not on this board are ignored."
  def reorder_activities(board, ids) when is_list(ids), do: reorder(StoryActivity, board_id(board), ids)

  @doc "Creates a task under `activity` (a struct or an id); `board_id` comes from the parent."
  def create_task(%StoryActivity{} = activity, attrs) do
    %StoryTask{board_id: activity.board_id, story_activity_id: activity.id}
    |> StoryTask.changeset(attrs)
    |> Repo.insert()
    |> broadcast_changed(activity.board_id)
  end

  def create_task(activity_id, attrs) when is_integer(activity_id) do
    create_task(Repo.get!(StoryActivity, activity_id), attrs)
  end

  @doc """
  Renames/repositions a task, and may move it to another activity **on the same board**.
  A cross-board move is rejected with `{:error, changeset}`.

  A move drags every card mapped to this task along with it: their `story_activity_id` is
  rewritten in the same transaction, so the card→cell invariant holds by derivation on this
  write path too. Each card that actually moved also gets its own `{:card_upserted, card}`
  (broadcast after the transaction commits) — `{:story_map_changed, board_id}` only tells
  receivers to refetch the *structure*.
  """
  def update_task(%StoryTask{} = task, attrs) do
    changeset =
      task
      |> StoryTask.changeset(attrs)
      |> validate_activity_on_board(task.board_id)

    result =
      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, updated} -> {updated, resync_mapped_cards(updated)}
          {:error, failed} -> Repo.rollback(failed)
        end
      end)

    case result do
      {:ok, {updated, cards}} ->
        Enum.each(cards, &Cards.notify_upserted/1)
        broadcast_changed({:ok, updated}, task.board_id)

      {:error, failed} ->
        {:error, failed}
    end
  end

  # The card→cell invariant is derived, never trusted: a task that changes activity drags its
  # mapped cards' `story_activity_id` with it. `IS DISTINCT FROM` so a card left in the
  # half-state (task set, activity nil) is repaired rather than skipped by NULL comparison.
  defp resync_mapped_cards(%StoryTask{} = task) do
    {_count, cards} =
      Repo.update_all(
        from(c in Card,
          where:
            c.story_task_id == ^task.id and
              fragment("? IS DISTINCT FROM ?", c.story_activity_id, ^task.story_activity_id),
          select: c
        ),
        set: [story_activity_id: task.story_activity_id, updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )

    cards
  end

  @doc """
  Deletes one task. Cards pointing at it keep `story_activity_id` and fall back into that
  activity's "No task yet" column (`story_task_id` nilified by the database).
  """
  def delete_task(%StoryTask{} = task) do
    task
    |> Repo.delete()
    |> broadcast_changed(task.board_id)
  end

  @doc "Rewrites the given tasks' `position` to `1..n`; ids not on this board are ignored."
  def reorder_tasks(board, ids) when is_list(ids), do: reorder(StoryTask, board_id(board), ids)

  @doc "Creates a release (swimlane) on `board`."
  def create_release(board, attrs) do
    id = board_id(board)

    %Release{board_id: id}
    |> Release.changeset(attrs)
    |> Repo.insert()
    |> broadcast_changed(id)
  end

  @doc "Renames/repositions a release."
  def update_release(%Release{} = release, attrs) do
    release
    |> Release.changeset(attrs)
    |> Repo.update()
    |> broadcast_changed(release.board_id)
  end

  @doc "Deletes a release. Cards in that swimlane keep their cell; only `release_id` is nilified."
  def delete_release(%Release{} = release) do
    release
    |> Repo.delete()
    |> broadcast_changed(release.board_id)
  end

  @doc "Rewrites the given releases' `position` to `1..n`; ids not on this board are ignored."
  def reorder_releases(board, ids) when is_list(ids), do: reorder(Release, board_id(board), ids)

  @doc """
  Places `card` on the story map. `attrs` is an atom-keyed map of `:story_activity_id`,
  `:story_task_id` and `:release_id` — it sets the **whole** placement, so anything omitted is
  cleared (`unassign_card/1` is the all-nil case) — plus an optional `:position`.

  `:position` is a **0-based index among the target cell's other cards** — the same contract
  `Relay.Cards.move_card/3` uses, so there is one meaning of "index" in the app. Omitted, the
  card is appended last. The whole target cell is renumbered `1..n` inside the transaction,
  exactly as `Cards.place_at/3` renumbers a stage: renumbering *all* of it is required for
  correctness, because on the first-ever drag into a cell every other card is still `nil` and
  writing only the moved card's position would slam it to the top however far down the user
  dropped it.

  `story_activity_id` is **derived** from `story_task_id` when a task is given, so a
  conflicting activity passed alongside is ignored rather than trusted. Every id is checked
  against the card's own board; a foreign activity, task or release is rejected with
  `{:error, changeset}` and nothing is written — including no renumber. Broadcasts
  `{:card_upserted, card}` via `Relay.Cards.notify_upserted/1` for the moved card **only**:
  every receiver's story-map refresh refetches the board's whole card list, so the renumbered
  siblings arrive with it, and broadcasting them individually would be N redundant re-renders
  per drop.
  """
  def assign_card(%Card{} = card, attrs) when is_map(attrs) do
    case resolve_placement(card, attrs) do
      {:ok, placement} ->
        card
        |> write_placement(placement, Map.get(attrs, :position))
        |> notify_card()

      {:error, field, message} ->
        {:error, card |> Card.story_map_changeset(%{}) |> Changeset.add_error(field, message)}
    end
  end

  @doc """
  Takes `card` off the story map entirely — all three columns **and** `story_map_position` nil.
  So the invariant is plain: a card in the tray has no story-map position, and re-placing it
  earns a fresh one. Broadcasts like `assign_card/2`.
  """
  def unassign_card(%Card{} = card) do
    assign_card(card, %{})
  end

  # The placement write and the cell renumber are one transaction, so a failure leaves neither.
  defp write_placement(%Card{} = card, placement, index) do
    Repo.transaction(fn ->
      case card |> Card.story_map_changeset(placement) |> Repo.update() do
        {:ok, moved} -> renumber_cell(moved, index)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Unmapped: a card in the tray carries no position.
  defp renumber_cell(%Card{story_activity_id: nil} = card, _index), do: set_story_map_position(card, nil)

  defp renumber_cell(%Card{} = card, index) do
    others = Repo.all(cell_query(card))
    index = clamp_index(index, length(others))

    others
    |> List.insert_at(index, card)
    |> Enum.with_index(1)
    |> Enum.map(fn {sibling, position} -> set_story_map_position(sibling, position) end)
    |> Enum.find(&(&1.id == card.id))
  end

  # The renumbered set is the **DB cell** — same board, same activity, same task, same release,
  # nil-safe (`IS NOT DISTINCT FROM`, matching the `IS DISTINCT FROM` already in
  # resync_mapped_cards/1). It is deliberately NOT the *display* cell: the last-lane fallback
  # for a release-less card is a display rule owned by RelayWeb.StoryMapGrid, and this context
  # may not reach into the web layer. The two differ only for a card with an activity and no
  # release, which renders in the last lane beside cards explicitly in it; those strays sort
  # last (nil position) and keep their board order — and every drop writes a release
  # explicitly, so a stray stops being one the first time anyone touches it.
  #
  # Ordering before the renumber is the order the grid displays (Postgres ASC is nulls last),
  # so a renumber never reshuffles what the user is looking at. Archived cards are excluded:
  # `Cards.list_cards/1` never shows them, so letting one consume an index would shift the
  # visible order for no reason. `type/2` because Ecto cannot infer a nil parameter's type
  # inside a fragment.
  defp cell_query(%Card{} = card) do
    from c in Card,
      where:
        c.board_id == ^card.board_id and c.id != ^card.id and is_nil(c.archived_at) and
          fragment("? IS NOT DISTINCT FROM ?", c.story_activity_id, type(^card.story_activity_id, :integer)) and
          fragment("? IS NOT DISTINCT FROM ?", c.story_task_id, type(^card.story_task_id, :integer)) and
          fragment("? IS NOT DISTINCT FROM ?", c.release_id, type(^card.release_id, :integer)),
      order_by: [asc: c.story_map_position, asc: c.stage_id, asc: c.position, asc: c.id]
  end

  defp clamp_index(nil, count), do: count
  defp clamp_index(index, count) when is_integer(index), do: index |> max(0) |> min(count)

  # force_change so the UPDATE always writes, even when a caller-held struct's in-memory value
  # coincidentally matches — the same guard Relay.Cards.reposition/2 uses.
  defp set_story_map_position(%Card{} = card, position) do
    changeset =
      card
      |> Changeset.change()
      |> Changeset.force_change(:story_map_position, position)

    case Repo.update(changeset) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Derivation, not trust: the task supplies its own activity, so the pair written to the card
  # can never disagree. Each id is fetched board-scoped, which is also the cross-board check.
  defp resolve_placement(%Card{board_id: board_id}, attrs) do
    with {:ok, task} <- fetch_scoped(StoryTask, Map.get(attrs, :story_task_id), board_id, :story_task_id),
         {:ok, activity} <-
           fetch_scoped(StoryActivity, Map.get(attrs, :story_activity_id), board_id, :story_activity_id),
         {:ok, release} <- fetch_scoped(Release, Map.get(attrs, :release_id), board_id, :release_id) do
      {:ok,
       %{
         story_task_id: task && task.id,
         story_activity_id: (task && task.story_activity_id) || (activity && activity.id),
         release_id: release && release.id
       }}
    end
  end

  defp fetch_scoped(_schema, nil, _board_id, _field), do: {:ok, nil}

  defp fetch_scoped(schema, id, board_id, field) do
    case Repo.get_by(schema, id: id, board_id: board_id) do
      nil -> {:error, field, "does not belong to this card's board"}
      record -> {:ok, record}
    end
  end

  defp validate_activity_on_board(changeset, board_id) do
    case Changeset.get_change(changeset, :story_activity_id) do
      nil ->
        changeset

      activity_id ->
        if Repo.exists?(from a in StoryActivity, where: a.id == ^activity_id and a.board_id == ^board_id) do
          changeset
        else
          Changeset.add_error(changeset, :story_activity_id, "must belong to the same board")
        end
    end
  end

  # One transaction, positions rewritten to 1..n in the order given. A `where` on board_id
  # means an id from another board simply matches nothing — no error, no cross-board write.
  defp reorder(schema, board_id, ids) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {:ok, _result} =
      Repo.transaction(fn ->
        ids
        |> Enum.with_index(1)
        |> Enum.each(fn {id, position} ->
          schema
          |> where([r], r.id == ^id and r.board_id == ^board_id)
          |> Repo.update_all(set: [position: position, updated_at: now])
        end)
      end)

    Events.broadcast(board_id, {:story_map_changed, board_id})
    :ok
  end

  defp broadcast_changed({:ok, _record} = result, board_id) do
    Events.broadcast(board_id, {:story_map_changed, board_id})
    result
  end

  defp broadcast_changed({:error, _changeset} = result, _board_id), do: result

  defp notify_card({:ok, %Card{} = card} = result) do
    :ok = Cards.notify_upserted(card)
    result
  end

  defp notify_card({:error, _changeset} = result), do: result

  defp board_id(%Board{id: id}), do: id
  defp board_id(id) when is_integer(id), do: id
end
