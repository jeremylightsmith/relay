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
  `move_task/3` is the single task-repositioning entry point the web layer calls — activity
  change plus renumber in one transaction — and it composes `update_task/2`'s derivation
  rather than repeating it.

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

  **Shared view settings (RE257, RE259).** The map's view state is board-wide, not per
  socket: `view_defaults/0` is the one definition of the key set (`"tray_open"`, `"zoom"`,
  `"hide_tasks"`, `"owner_filter"`, `"needs_input_filter"`, `"collapsed"`, `"focus"`,
  `"hide_complete"`), `filter_keys/0` is which of those are filters and `filters_active?/1`
  answers whether they differ from the defaults (RE276),
  `view/1` merges it under the stored `boards.story_map_view` column dropping unknown keys,
  and every write goes through `merge_view/2` — `put_view/3` is one key, `toggle_view/2`
  flips a boolean and `toggle_view_member/4` flips one member of a list, both computed on the
  committed row so fast clicks cannot collapse into one. A write persists once and broadcasts
  `{:story_map_view_changed, board_id, view}` on `"story_map_view:<board_id>"` once.
  Deliberately **not** through `Relay.Events`: that bumps the board version on every call,
  and a view toggle is not a domain mutation. Persisted rather than in ETS so a late joiner
  and a post-deploy reload both see the view everyone else is on. Deliberately NOT shared:
  `story_map_draft`, `story_map_draft_name` and `story_map_compose` stay per-tab (RE263), so
  another tab's refresh can never eat what you are typing.

  **Deleting structure is refused while it still holds cards.** `delete_activity/1`,
  `delete_task/1` and `delete_release/1` return `{:error, :not_empty}` when any **non-archived**
  card on the board still points at them, checked inside the delete's own transaction. The
  `is_nil(archived_at)` filter is not optional: `Relay.Cards.list_cards/1` never shows archived
  cards, so a structure holding only archived ones renders an enabled ✕ that the server must
  honour. There is no "last release" guard — that one is a display rule owned by the view.

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

  @pubsub Relay.PubSub

  # RE257 — the ONE definition of the shared story-map view key set and its defaults
  # (AGENTS.md: a magic value is defined exactly once). Nothing anywhere else re-types the
  # key list, and the SHAPE of a key's default is load-bearing: boolean keys toggle through
  # `toggle_view/2`, list keys flip a member through `toggle_view_member/4`, everything goes
  # through the one `merge_view/2` writer.
  #
  # "zoom" and "hide_tasks" are RE260's chrome controls, shared for the same reason the tray
  # is: RE257's cursors ship raw pixel coordinates in the map's scroll space, and both
  # settings change the grid's GEOMETRY — hide_tasks collapses each activity to one merged
  # column and zoom resizes every cell — so two viewers who disagree see each other's cursor
  # over the wrong card, not merely a few pixels off. The column is jsonb, so zoom is stored
  # as a STRING and comes back through `RelayWeb.StoryMapComponents.parse_zoom/1`, never
  # `String.to_atom/1`.
  #
  # RE259's four filter/focus keys are shared for a HARDER version of that reason: collapse
  # and focus change grid geometry more violently than zoom does — a whole band becomes a
  # 50px stub — so per-socket filters would put every other viewer's cursor on the wrong
  # card. The cost is real and deliberate: one viewer's filter narrows the map for everyone,
  # which is the point on a shared planning surface ("everyone look at Checkout").
  # "owner_filter" holds `RelayWeb.StoryMapFilter`'s owner keys, "collapsed" holds
  # story_activity ids, and "focus" holds one story_activity id or nil.
  #
  # RE276's "hide_complete" is the first key whose default is ON: the map opens showing only
  # incomplete cards. It is shared for the same geometry reason as the rest — a filter that
  # empties a band changes what every other viewer's cursor is over. Its default being `true`
  # is what makes `filter_keys/0` and `filters_active?/1` below necessary: "off" and "default"
  # are no longer the same place, so "is a filter on" has to mean "does it differ from the
  # board's defaults".
  @view_defaults %{
    "tray_open" => true,
    "zoom" => "compact",
    "hide_tasks" => false,
    "owner_filter" => [],
    "needs_input_filter" => false,
    "collapsed" => [],
    "focus" => nil,
    "hide_complete" => true
  }

  # RE276 — which of the view keys are FILTERS: the subset `Clear` resets to `view_defaults/0`
  # and the subset `filters_active?/1` compares against it. Collapse, focus, zoom, hide_tasks
  # and the tray narrow or resize the view but are not filters — RE259 drew that line and it
  # stands. Written here so `RelayWeb.BoardLive`'s `clear_story_map_filters` stops re-typing a
  # literal of filter keys, which would be a second place to forget one.
  @filter_keys ["owner_filter", "needs_input_filter", "hide_complete"]

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

  @doc """
  The artboard's `reorder/3` (`docs/designs/Relay Story Map.dc.html`, line ~679), pure and
  query-free like `next_position/1`: remove `id` from `ids` and re-insert it at `target_id`'s
  index — i.e. immediately **before** the target — appending when the target is not in the
  list. Dropping something on itself is the identity.

  All three header drops (activity, task, release) order through this, so the insert rule has
  one home and no call site re-types it.

      insert_before([1, 2, 3], 3, 1) #=> [3, 1, 2]
      insert_before([1, 2, 3], 1, 9) #=> [2, 3, 1]
  """
  def insert_before(ids, id, target_id) when is_list(ids) do
    if id == target_id do
      ids
    else
      rest = Enum.reject(ids, &(&1 == id))

      case Enum.find_index(rest, &(&1 == target_id)) do
        nil -> rest ++ [id]
        index -> List.insert_at(rest, index, id)
      end
    end
  end

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
  Deletes an activity — **refused with `{:error, :not_empty}` while any non-archived card on
  this board still points at it**. On success the database cascade deletes its tasks and
  **unmaps** every card that pointed at either; `release_id` is untouched.
  """
  def delete_activity(%StoryActivity{} = activity) do
    guarded_delete(activity, :story_activity_id, activity.id, activity.board_id)
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
  Repositions a task, and may move it to another activity **on the same board** — the single
  entry point the web layer calls, so no call site branches on "did the activity change".

  `ordered_task_ids` is the TARGET activity's full desired task order, including the moved
  task. In one transaction: the activity change (reusing `update_task/2`'s own
  `resync_mapped_cards/1`, so the card→cell invariant keeps holding by derivation), then a
  renumber of `ordered_task_ids` to `1..n`, board-scoped. Within one activity this degenerates
  to a pure renumber and moves no card.

  Broadcasts one `{:story_map_changed, board_id}` after commit, plus one
  `{:card_upserted, card}` per card the activity change actually moved — exactly the contract
  `update_task/2` already honours. A cross-board target is rejected with `{:error, changeset}`
  by `validate_activity_on_board/2`, which this inherits.

  `reorder_tasks/2` stays the primitive this renumbers through.
  """
  def move_task(%StoryTask{} = task, target_activity_id, ordered_task_ids) when is_list(ordered_task_ids) do
    changeset =
      task
      |> StoryTask.changeset(%{story_activity_id: target_activity_id})
      |> validate_activity_on_board(task.board_id)

    result =
      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, updated} ->
            cards = resync_mapped_cards(updated)
            renumber(StoryTask, task.board_id, ordered_task_ids)
            # The renumber is an update_all, so the in-memory struct's position is stale.
            {Repo.reload!(updated), cards}

          {:error, failed} ->
            Repo.rollback(failed)
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

  @doc """
  Deletes one task — **refused with `{:error, :not_empty}` while any non-archived card on this
  board still points at it**. On success, cards that pointed at it would keep
  `story_activity_id` and fall into that activity's "No task yet" column; the guard means there
  are none.
  """
  def delete_task(%StoryTask{} = task) do
    guarded_delete(task, :story_task_id, task.id, task.board_id)
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

  @doc """
  Deletes a release (swimlane) — **refused with `{:error, :not_empty}` while any non-archived
  card on this board still carries its `release_id`**. Cards keep their cell either way; only
  `release_id` is nilified.

  There is deliberately no "last release" guard here: that rule is a *display* one (the ✕ is
  not rendered at all when the board has a single release, the artboard's
  `canDelete: rels.length > 1`), and `RelayWeb.StoryMapGrid` already renders a board with zero
  releases as one synthetic `(No release)` lane.
  """
  def delete_release(%Release{} = release) do
    guarded_delete(release, :release_id, release.id, release.board_id)
  end

  # The count and the delete run in ONE transaction, so a card assigned concurrently cannot
  # slip through the gap between them. `{:error, :not_empty}` is a deliberately new shape
  # alongside the existing `{:ok, _} | {:error, changeset}`: the greyed ✕ is UI only, and a
  # forged event must not delete a structure that still holds cards.
  defp guarded_delete(record, field, id, board_id) do
    fn ->
      if holds_cards?(field, id, board_id), do: Repo.rollback(:not_empty), else: delete_or_rollback(record)
    end
    |> Repo.transaction()
    |> broadcast_changed(board_id)
  end

  defp delete_or_rollback(record) do
    case Repo.delete(record) do
      {:ok, deleted} -> deleted
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # "Non-empty" is ONE rule for all three structures: any non-archived card on this board
  # pointing at it. `is_nil(archived_at)` is not optional — `Relay.Cards.list_cards/1` never
  # shows archived cards, so the story map counts 0 and renders an ENABLED ✕; without the
  # filter the server would then refuse that click, which is a dead button.
  defp holds_cards?(field, id, board_id) do
    Repo.exists?(
      from c in Card,
        where: c.board_id == ^board_id and is_nil(c.archived_at) and field(c, ^field) == ^id
    )
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
  per drop. The renumbered siblings also keep their `updated_at`: only the moved card is
  re-stamped, so a map drag cannot reorder the board-lens surfaces that sort on recency.
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

  defp renumber_cell(%Card{id: moved_id} = card, index) do
    others = Repo.all(cell_query(card))
    index = clamp_index(index, length(others))

    others
    |> List.insert_at(index, card)
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%Card{id: ^moved_id} = moved, position} -> set_story_map_position(moved, position)
      {sibling, position} -> set_sibling_position(sibling, position)
    end)
    |> Enum.find(&(&1.id == moved_id))
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

  # A sibling is renumbered with a bare UPDATE of the one column, deliberately NOT the changeset
  # path the moved card takes, so its `updated_at` is left alone. This diverges from
  # `Cards.place_at/3`, on purpose: `updated_at` is this app's recency proxy behind two orderings
  # that live in the *board* lens — the terminal Done column's render window
  # (`Cards.list_stage_cards/2`) and `coalesce(blocked_since, updated_at)` in
  # `Cards.needs_you_feed/1`. A story-map cell spans every stage by construction, so re-stamping a
  # sibling would reorder the Done column and every member's needs-you feed off a drag those
  # surfaces never show. Returns the struct it was given with the new position applied, so
  # renumber_cell/2 still gets a full row back for the moved card's neighbours.
  defp set_sibling_position(%Card{} = card, position) do
    Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [story_map_position: position])
    %{card | story_map_position: position}
  end

  # The moved card DOES go through the changeset: it genuinely changed, so the `updated_at` bump
  # is correct, and `Cards.notify_upserted/1` needs the reloaded struct.
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

  # One transaction, positions rewritten to 1..n in the order given, then the broadcast.
  defp reorder(schema, board_id, ids) do
    {:ok, :ok} = Repo.transaction(fn -> renumber(schema, board_id, ids) end)

    Events.broadcast(board_id, {:story_map_changed, board_id})
    :ok
  end

  # The renumber itself: no transaction, no broadcast, so `move_task/3` can compose it into its
  # own. A `where` on board_id means an id from another board simply matches nothing — no
  # error, no cross-board write.
  defp renumber(schema, board_id, ids) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    ids
    |> Enum.with_index(1)
    |> Enum.each(fn {id, position} ->
      schema
      |> where([r], r.id == ^id and r.board_id == ^board_id)
      |> Repo.update_all(set: [position: position, updated_at: now])
    end)
  end

  @doc """
  The shared story-map view settings and their defaults — the single source of truth for the
  key set. `view/1` merges over it and `put_view/3` validates against it, so a key can only
  ever be added in one place.
  """
  def view_defaults, do: @view_defaults

  @doc """
  `board`'s shared story-map view: `view_defaults/0` with the stored map merged over it, and
  any stored key that is no longer in the default set **dropped** — so a setting removed from
  `view_defaults/0` can never resurrect from an old row.
  """
  def view(%Board{} = board) do
    stored = board.story_map_view || %{}

    Map.merge(@view_defaults, Map.take(stored, Map.keys(@view_defaults)))
  end

  @doc """
  The subset of `view_defaults/0`'s keys that are FILTERS — the keys `Clear` resets and
  `filters_active?/1` compares.

  The one definition: `RelayWeb.BoardLive`'s `clear_story_map_filters` merges
  `Map.take(view_defaults(), filter_keys())` rather than re-typing a literal, so adding a
  fourth filter later needs no change there.
  """
  def filter_keys, do: @filter_keys

  @doc """
  Whether `view`'s filters differ from the board's defaults — what drives the `Clear` link.

  Deliberately **not** "any filter is on". With `hide_complete` defaulting to `true`, "off"
  and "default" are no longer the same place, and the default is the one worth one-clicking
  back to. So `Clear` appears once hide-complete is switched OFF, reached without
  special-casing an unchecked box as "a filter".

  It lives here, beside the two things it derives from, rather than in
  `RelayWeb.StoryMapFilter` — which is why that module's `active?/2` is gone: two answers to
  "is a filter on" is exactly the drift the one-definition rule exists to stop.
  """
  def filters_active?(view) when is_map(view) do
    Map.take(view, @filter_keys) != Map.take(@view_defaults, @filter_keys)
  end

  @doc """
  Writes several shared view settings **in one row write and one broadcast**, and is the
  single writer every other one composes.

  Board-wide and shared on purpose: every viewer of a board looks at the *same* map, which is
  what makes RE257's raw-pixel cursors land on the right card for everyone.

  Validates **every** key against `view_defaults/0` before touching the row: one unknown key
  refuses the whole batch with `{:error, :unknown_key}` and writes nothing, so a stale or
  forged client cannot inject arbitrary keys into the board row. The board row is **re-read**
  rather than trusted from the caller's struct: with seven keys in the set, merging into a
  stale in-memory view would silently clobber another session's write.

  One write means "expand this activity **and** turn Hide tasks off" is atomic and sends ONE
  `{:story_map_view_changed, board_id, view}` on `"story_map_view:<board_id>"`, not three —
  deliberately NOT through `Relay.Events`, which bumps the board version on every call. A
  view change is not a domain mutation and must never make the CLI refetch the board.
  """
  def merge_view(%Board{id: id}, changes) when is_map(changes) do
    if known_keys?(Map.keys(changes)) do
      write_view(id, &Map.merge(&1, changes))
    else
      {:error, :unknown_key}
    end
  end

  @doc """
  Writes one shared view setting — `merge_view/2` with a single key, kept because it is the
  shape most call sites want and its contract predates the batch writer.
  """
  def put_view(%Board{} = board, key, value) when is_binary(key) do
    merge_view(board, %{key => value})
  end

  @doc """
  Flips one **boolean** shared view setting — the read-modify-write done **inside one call**,
  on the committed row.

  Not `put_view(board, key, not assigns.thing)`: a LiveView's assign only catches up when it
  processes the `{:story_map_view_changed, ...}` message the write sent, which `send/2` puts
  at the TAIL of its mailbox — behind any click that already arrived. Two fast clicks would
  both compute the flip from the same stale value and write it twice, so two clicks made one
  toggle.

  A key whose default is not a boolean is refused with `{:error, :not_a_toggle}` and writes
  nothing. Without that guard one wrong call site would replace the `"collapsed"` LIST with
  `true` and every viewer's map would break — `flip/1`'s "anything not `true` is off"
  fallback would do it silently. The closed set is therefore self-describing: boolean keys
  toggle, list keys toggle a member, everything else is a `put`.
  """
  def toggle_view(%Board{id: id}, key) when is_binary(key) do
    with :ok <- known_key(key),
         :ok <- expect_default(key, &is_boolean/1, :not_a_toggle) do
      write_view(id, &Map.put(&1, key, flip(Map.fetch!(&1, key))))
    end
  end

  @doc """
  Flips one member in and out of a **list-valued** shared view setting — the owner chips and
  the collapsed set — on the committed row, for exactly the reason `toggle_view/2` gives: an
  assign lags a render behind, so two fast clicks computed from it would both flip from the
  same stale value.

  `extra` is merged into the **same** write, so a toggle that must also clear another key is
  one row write and one broadcast. Collapsing uses it: the artboard's `toggleCollapse` clears
  focus in the same update (`docs/designs/Relay Story Map.dc.html`, line ~659), and it must —
  while focusing, `▾` on the focused band would otherwise collapse the only expanded activity.

  A key whose default is not a list is refused with `{:error, :not_a_list}`; an unknown key,
  in `key` or anywhere in `extra`, with `{:error, :unknown_key}`. Neither writes anything.
  """
  def toggle_view_member(%Board{id: id}, key, member, extra \\ %{}) when is_binary(key) and is_map(extra) do
    with :ok <- known_key(key),
         :ok <- known_keys(Map.keys(extra)),
         :ok <- expect_default(key, &is_list/1, :not_a_list) do
      write_view(id, fn current ->
        current
        |> Map.put(key, toggle_member(List.wrap(Map.fetch!(current, key)), member))
        |> Map.merge(extra)
      end)
    end
  end

  defp toggle_member(list, member) do
    if member in list, do: List.delete(list, member), else: list ++ [member]
  end

  defp known_key(key), do: if(Map.has_key?(@view_defaults, key), do: :ok, else: {:error, :unknown_key})

  defp known_keys(keys), do: if(known_keys?(keys), do: :ok, else: {:error, :unknown_key})

  defp known_keys?(keys), do: Enum.all?(keys, &Map.has_key?(@view_defaults, &1))

  # The DEFAULT's shape is what types a key, not the stored value: a row hand-edited to hold
  # a string under "hide_tasks" must still toggle rather than be reclassified.
  defp expect_default(key, predicate, error) do
    if predicate.(Map.fetch!(@view_defaults, key)), do: :ok, else: {:error, error}
  end

  defp flip(value) when is_boolean(value), do: not value
  # Only reachable if a non-boolean was written to a boolean key by hand; treat anything that
  # is not `true` as off so a toggle can never crash a viewer's socket.
  defp flip(_other), do: true

  # The one row write: re-read, apply, persist, broadcast. Every public writer above is a
  # different way of building `fun`, so validation and the re-read exist exactly once.
  defp write_view(id, fun) do
    board = Repo.get!(Board, id)
    updated = fun.(view(board))

    case board |> Board.story_map_view_changeset(%{story_map_view: updated}) |> Repo.update() do
      {:ok, _board} ->
        broadcast_view(id, updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Subscribes the calling process to `board_id`'s shared story-map view topic."
  def subscribe_view(board_id), do: Phoenix.PubSub.subscribe(@pubsub, view_topic(board_id))

  @doc "The shared story-map view topic for `board_id`."
  def view_topic(board_id), do: "story_map_view:#{board_id}"

  # Fire-and-forget, mirroring Relay.Events.broadcast/2's contract: a PubSub failure can never
  # fail the interaction that triggered it.
  defp broadcast_view(board_id, view) do
    _ = Phoenix.PubSub.broadcast(@pubsub, view_topic(board_id), {:story_map_view_changed, board_id, view})
    :ok
  end

  defp broadcast_changed({:ok, _record} = result, board_id) do
    Events.broadcast(board_id, {:story_map_changed, board_id})
    result
  end

  defp broadcast_changed({:error, _reason} = result, _board_id), do: result

  defp notify_card({:ok, %Card{} = card} = result) do
    :ok = Cards.notify_upserted(card)
    result
  end

  defp notify_card({:error, _changeset} = result), do: result

  defp board_id(%Board{id: id}), do: id
  defp board_id(id) when is_integer(id), do: id
end
