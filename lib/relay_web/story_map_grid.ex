defmodule RelayWeb.StoryMapGrid do
  @moduledoc """
  The story map's pure view model (RE264): `(activities, tasks, releases, cards, draft,
  hide_tasks?, collapsed)` in, a fully placed grid out. No Ecto, no LiveView, no side effects — every placement rule the
  artboard (`docs/designs/Relay Story Map.dc.html`, `eff/1`) encodes lives here, so the rules
  are unit-testable without mounting a LiveView.

  **The invariant: no card can disappear.** Every card handed to `build/7` is accounted for
  exactly once — in one `cells` entry, in `unmapped`, or in the `count` of exactly one
  collapsed stub column. The three-way partition sums to `total`, which is a testable
  statement rather than a weakened one, and a test asserts the sum. The placement rules are
  ordered and the last one is total:

    1. no activity, or an activity this board does not have, goes to the tray — *even if the
       card has a release* (the artboard's `unmappedAll = !e.act && !e.task`);
    2. an activity plus a task that is a real column goes to that task's column;
    3. otherwise (activity set) it falls into that activity's `— No task yet` column.

  A card's effective activity is **derived from its task** when the task is known, mirroring
  `Relay.StoryMap`'s own derivation (and the artboard's `ownerAct/1`), so a column and its band
  can never disagree about which activity a card belongs to. Expressing rule 3 as the
  *fallback* rather than a defensive branch is what makes the invariant hold with no
  special-case code: a `story_task_id` this board does not have simply resolves to no task, and
  rule 3 catches it.

  Lane placement mirrors it: the card's release when the board has it, otherwise **the last
  lane by position**. The artboard hardcodes `if (act && !rel) rel = 'later'`; generalizing to
  *last* means the rule survives a board that renames or reorders its swimlanes under RE261.
  This is a **display rule only** — nothing here writes a `release_id`, exactly as RE265's spec
  assigns it to this card. A board with zero releases (possible once RE261 ships deletes)
  renders one synthetic `(No release)` lane rather than dropping every mapped card on the floor.

  The `— No task yet` column renders only when at least one card lands in it (the artboard's
  `if(ntCount)`) — except for an activity with no tasks at all, which still gets one empty
  column so its band has something to span (the artboard's `Math.max(span, 1)`).

  **Hide tasks (RE260).** With `hide_tasks?` true each activity collapses to a SINGLE column
  keyed `"m:<activity_id>"`, holding every card of that activity — cards on any of its tasks
  *and* its task-less cards alike (the artboard's `col.merged ||` short circuit, line ~518).
  The per-activity `— No task yet` column does not render separately while merged, every band's
  `span` is 1, and the no-card-can-disappear invariant is untouched: the merge changes only
  which column key a card's cell carries, never whether it has one.

  **Collapse and focus (RE259).** `collapsed` is a MapSet of activity ids (the same trailing
  defaulted-parameter choice this module already documents for `hide_tasks?`); focus is not a
  separate argument because focus **is** a collapse of everything else, resolved by
  `collapsed_set/3`. A collapsed activity contributes exactly one column,
  `%{key: "c:<activity_id>", collapsed?: true, count: n, …}` — `collapsed?` joins `no_task?` /
  `bare?` / `draft?` / `merged?` — and **no band**, because the renderer's stub spans
  `grid-row:1 / -1` in the band's place. Its cards render nowhere and are counted on the stub
  instead. **Collapse wins over Hide tasks** (the artboard's `if(collapsed) … else
  if(hideTasks)` order), so a collapsed activity is a stub whether or not tasks are merged.
  `decode_placement/2` has no `"c:"` clause, so a stub can never be a drop target even if a
  forged drop reaches the server — belt and braces alongside the renderer not marking it
  droppable. `total` is the count of the cards `build/7` was **given**, which under
  `RelayWeb.BoardLive`'s filter pre-pass is the VISIBLE count; the lane counts likewise tally
  only what renders, so a lane label narrows with the filter and with collapse exactly as the
  artboard's `relLabels` does.

  Keys are strings so they go straight into DOM ids: a task column is `"t:<task_id>"`, a
  no-task column `"nt:<activity_id>"`, a merged column `"m:<activity_id>"`, a collapsed stub
  `"c:<activity_id>"`, a lane `"r:<release_id>"` or `"r:none"`.

  No `use Boundary` — a pure web-layer helper inside the `RelayWeb` boundary, like
  `RelayWeb.FlowLayout`.
  """

  @none_lane_key "r:none"

  defstruct bands: [], columns: [], lanes: [], cells: %{}, unmapped: [], total: 0

  @doc """
  Builds the grid. `activities`, `tasks` and `releases` are the board's structure in `position`
  order (`Relay.StoryMap.list_activities/1`, `list_tasks/1`, `list_releases/1`); `cards` is the
  board's non-archived cards in `Relay.Cards.list_cards/1`
  order. The **tray** preserves that order exactly. A **cell** re-sorts it by
  `story_map_position` ascending, nils last (RE262), so a cell nobody has dragged in still
  renders in board order and a cell somebody has ordered renders in theirs.

  `draft` (RE263) is the page's open inline draft — `nil`, `:activity`, `:release`, or
  `{:task, activity_id}`. Only the last shape reaches the view model: it appends one draft
  column to that activity, growing its `span` by 1 and moving `last_of_activity?` onto it, and
  it **replaces** the placeholder column when the activity has neither tasks nor task-less
  cards. Everything else about the grid — placement, lanes, the tray, `total` — is unchanged,
  so the no-card-can-disappear invariant holds with a draft open.

  `hide_tasks?` (RE260) collapses each activity to one `"m:<activity_id>"` column — see the
  module doc. It is deliberately a trailing defaulted parameter rather than a keyword-opts
  refactor, so RE264's existing call sites and tests are untouched. A `{:task, _}` draft and
  `hide_tasks?` never co-exist (`RelayWeb.BoardLive` turns Hide tasks off when a task draft
  opens), and the merged branch ignores the draft outright, so the pair is still total.

  `collapsed` (RE259) is a MapSet of activity ids that render as stubs — derive it with
  `collapsed_set/3` rather than by hand, so the focus rule has one home. Like `hide_tasks?`
  it is a trailing defaulted parameter, so RE264's existing call sites and tests are
  untouched.

  Fields of the returned struct:

    * `bands` — `[%{activity:, span:, count:, start:}]`, one per activity, left to right.
      `start` is the **0-based index into `columns`** of the band's first column; `span` how
      many columns it covers (always ≥ 1); `count` how many cards sit under it. A collapsed
      activity contributes no band.
    * `columns` — `[%{key:, activity:, task:, no_task?:, bare?:, draft?:, merged?:,
      collapsed?:, task_count:, last_of_activity?:, count:}]`, left to right. `bare?` marks a
      `— No task yet` column that holds no cards, which the renderer turns into the clickable
      `＋ Add task` invitation (the artboard's `bare`); `draft?` marks RE263's open new-task
      column, whose key is `"draft:<activity_id>"` and which never appears in `cells`; `count`
      is how many cards sit in it, and is what RE261's ✕ blocks on; `merged?` marks RE260's
      Hide-tasks column, whose `task_count` is the activity's task count for the
      `<n> tasks · merged` header (unrelated to `count`, the card tally); `collapsed?` marks
      RE259's stub column, whose `count` is how many cards are hidden under it.
    * `lanes` — `[%{key:, release:, count:}]`, top to bottom. `release` is `nil` on the
      synthetic `(No release)` lane.
    * `cells` — `%{{column_key, lane_key} => [card]}`. A pair with no cards is simply absent.
    * `unmapped` — the tray's cards.
    * `total` — `length(cards)`.
  """
  def build(activities, tasks, releases, cards, draft \\ nil, hide_tasks? \\ false, collapsed \\ MapSet.new()) do
    tasks_by_id = Map.new(tasks, &{&1.id, &1})
    activity_ids = MapSet.new(activities, & &1.id)
    tasks_by_activity = Enum.group_by(tasks, & &1.story_activity_id)

    placements = Enum.map(cards, &place(&1, tasks_by_id, activity_ids))

    no_task_ids =
      for {:grid, activity_id, nil, _card} <- placements, into: MapSet.new(), do: activity_id

    {columns, bands} =
      backbone(activities, tasks_by_activity, no_task_ids, draft_activity_id(draft), hide_tasks?, collapsed)

    lanes = lane_list(releases)

    {cells, unmapped, stub_counts} =
      fill(placements, MapSet.new(lanes, & &1.key), last_key(lanes), hide_tasks?, collapsed)

    columns = count_columns(columns, cells, stub_counts)

    %__MODULE__{
      bands: count_bands(bands, columns),
      columns: columns,
      lanes: count_lanes(lanes, cells),
      cells: cells,
      unmapped: unmapped,
      total: length(cards)
    }
  end

  # RE263 — only a `{:task, activity_id}` draft reaches the view model: `:activity` and
  # `:release` are chrome the renderer owns, and an id this board does not have (a stale draft
  # after another tab deleted the activity) simply never matches, so the grid renders as if
  # there were no draft at all.
  defp draft_activity_id({:task, activity_id}), do: activity_id
  defp draft_activity_id(_draft), do: nil

  @doc """
  The set of activity ids that render as a **stub** — the one place the focus rule lives, so
  `RelayWeb.BoardLive` holds no policy about it.

  With no focus it is `collapsed_ids` intersected with the board's real activities, so a
  stale entry left over after RE261 deleted an activity is inert. **With a focus it is every
  activity except the focused one** — focus *is* a collapse of everything else (the
  artboard's line ~406) — and the focused activity is never in the set even when
  `collapsed_ids` names it. That last clause is what makes this total: no combination of
  stored keys, including a row raced in from another tab, can collapse every band and blank
  the map. An unresolvable focus id is no focus at all (`resolve_focus/2`).
  """
  def collapsed_set(activities, collapsed_ids, focus_id) do
    ids = MapSet.new(activities, & &1.id)

    case resolve_focus(activities, focus_id) do
      nil -> collapsed_ids |> List.wrap() |> MapSet.new() |> MapSet.intersection(ids)
      focus -> MapSet.delete(ids, focus.id)
    end
  end

  @doc """
  The focused activity struct, or `nil` when there is no focus or the id is one this board
  does not have. The `nil` matters: if the focused activity is deleted in another tab, an
  unresolved focus would collapse **every** band. An unknown id is no focus.
  """
  def resolve_focus(activities, focus_id) do
    focus_id && Enum.find(activities, &(&1.id == focus_id))
  end

  @doc """
  The DOM id of one body cell. `:` is not legal in a CSS selector, so the keys' colons become
  dashes — one definition, called by the renderer and by the tests that address a cell.
  """
  def cell_dom_id(column_key, lane_key), do: cell_element_id("cell", column_key, lane_key)

  @doc """
  The DOM id of one of a cell's own elements (RE262): `cell_element_id("add", c, l)` is the
  cell's `＋` button, `"compose"` its composer. `cell_dom_id/2` is the `"cell"` prefix of the
  same rule, so the `:` → `-` substitution exists exactly once.
  """
  def cell_element_id(prefix, column_key, lane_key) do
    "story-map-#{prefix}-#{dash(column_key)}-#{dash(lane_key)}"
  end

  defp dash(key), do: String.replace(key, ":", "-")

  @doc """
  Decodes a column key + lane key into the placement attrs `Relay.StoryMap.assign_card/2`
  takes. This module *defines* the key formats, so it also parses them — the format is written
  once and `RelayWeb.BoardLive` never string-matches on `"nt:"`.

      decode_placement("t:7", "r:2")     #=> {:ok, %{story_task_id: 7, release_id: 2}}
      decode_placement("nt:3", "r:none") #=> {:ok, %{story_activity_id: 3, release_id: nil}}
      decode_placement("x:1", "r:2")     #=> :error

  A task column sends **only** the task: the activity is derived from it by `assign_card/2`,
  so the client can never make a column and its band disagree.
  """
  def decode_placement(column_key, lane_key) do
    with {:ok, column} <- decode_column(column_key),
         {:ok, release_id} <- decode_lane(lane_key) do
      {:ok, Map.put(column, :release_id, release_id)}
    end
  end

  @doc """
  Whether `column_key` is RE260's merged (Hide tasks) column. This module defines the key
  formats, so it answers questions about them too — `RelayWeb.BoardLive` needs to know a drop
  landed on an activity-wide column in order to preserve the card's task, and asks here rather
  than string-matching on `"m:"` itself.
  """
  def merged_column?("m:" <> _activity_id), do: true
  def merged_column?(_other), do: false

  defp decode_column("t:" <> id) do
    with {:ok, id} <- decode_id(id), do: {:ok, %{story_task_id: id}}
  end

  defp decode_column("nt:" <> id) do
    with {:ok, id} <- decode_id(id), do: {:ok, %{story_activity_id: id}}
  end

  # RE260 — a merged column names an ACTIVITY, exactly like `nt:`. The two differ only in what
  # the caller may do with a card's EXISTING task on a drop (`RelayWeb.BoardLive` asks via
  # `merged_column?/1`), never in what they decode to.
  defp decode_column("m:" <> id) do
    with {:ok, id} <- decode_id(id), do: {:ok, %{story_activity_id: id}}
  end

  defp decode_column(_other), do: :error

  defp decode_lane(@none_lane_key), do: {:ok, nil}
  defp decode_lane("r:" <> id), do: decode_id(id)
  defp decode_lane(_other), do: :error

  defp decode_id(string) do
    case Integer.parse(string) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> :error
    end
  end

  # Rules 1 vs 2/3, and the task → activity derivation, in one place. A task id that is not on
  # this board resolves to `nil`, so the card falls to rule 3 rather than off the grid.
  defp place(card, tasks_by_id, activity_ids) do
    task = card.story_task_id && Map.get(tasks_by_id, card.story_task_id)
    activity_id = (task && task.story_activity_id) || card.story_activity_id

    if activity_id && MapSet.member?(activity_ids, activity_id) do
      {:grid, activity_id, task && task.id, card}
    else
      {:tray, card}
    end
  end

  defp backbone(activities, tasks_by_activity, no_task_ids, draft_activity_id, hide_tasks?, collapsed) do
    {grouped, _next} =
      Enum.map_reduce(activities, 0, fn activity, start ->
        backbone_group(
          MapSet.member?(collapsed, activity.id),
          activity,
          start,
          tasks_by_activity,
          no_task_ids,
          draft_activity_id,
          hide_tasks?
        )
      end)

    {Enum.flat_map(grouped, &elem(&1, 0)), grouped |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)}
  end

  # RE259 — a collapsed activity is ONE column and NO band: the stub spans `grid-row:1 / -1`
  # in the band's place (the artboard's `topCells` stub branch, line ~416), so a band header
  # rendered over it would be a second header.
  defp backbone_group(true, activity, start, _tasks_by_activity, _no_task_ids, _draft_activity_id, _hide_tasks?) do
    {{[collapsed_column(activity)], nil}, start + 1}
  end

  defp backbone_group(false, activity, start, tasks_by_activity, no_task_ids, draft_activity_id, hide_tasks?) do
    tasks = Map.get(tasks_by_activity, activity.id, [])

    columns =
      if hide_tasks? do
        [merged_column(activity, length(tasks))]
      else
        unmerged_columns(activity, tasks, no_task_ids, draft_activity_id)
      end

    columns = mark_last(columns)
    band = %{activity: activity, span: length(columns), count: 0, start: start}

    {{columns, band}, start + length(columns)}
  end

  # RE259 — the stub. `last_of_activity?` is set directly rather than through `mark_last/1`
  # because the activity is exactly one column wide by construction.
  defp collapsed_column(activity) do
    %{
      key: "c:#{activity.id}",
      activity: activity,
      task: nil,
      no_task?: false,
      bare?: false,
      draft?: false,
      merged?: false,
      collapsed?: true,
      task_count: 0,
      last_of_activity?: true,
      count: 0
    }
  end

  defp unmerged_columns(activity, tasks, no_task_ids, draft_activity_id) do
    draft? = activity.id == draft_activity_id
    no_task_cards? = MapSet.member?(no_task_ids, activity.id)

    # RE263 — the draft column stands in for the empty placeholder, so the user never sees
    # `＋ Add task` and an open input side by side. An activity that still holds task-less
    # CARDS keeps its `— No task yet` column: real cards live in it.
    no_task? = no_task_cards? or (tasks == [] and not draft?)

    if(no_task?, do: [no_task_column(activity, not no_task_cards?)], else: []) ++
      Enum.map(tasks, &task_column(activity, &1)) ++
      if(draft?, do: [draft_column(activity)], else: [])
  end

  # RE260 — Hide tasks. One column per activity, holding every card under it. `task_count` is
  # the artboard's `tasks.length` for the `<n> tasks · merged` header (line ~442); it is the
  # ONLY reason the count is carried here rather than derived by the renderer, which has no
  # task list.
  defp merged_column(activity, task_count) do
    %{
      key: "m:#{activity.id}",
      activity: activity,
      task: nil,
      no_task?: false,
      bare?: false,
      draft?: false,
      merged?: true,
      collapsed?: false,
      task_count: task_count,
      last_of_activity?: false,
      count: 0
    }
  end

  defp task_column(activity, task) do
    %{
      key: "t:#{task.id}",
      activity: activity,
      task: task,
      no_task?: false,
      bare?: false,
      draft?: false,
      merged?: false,
      collapsed?: false,
      task_count: 0,
      last_of_activity?: false,
      count: 0
    }
  end

  # `bare?` is the artboard's `bare = !ntCount` (line ~450): a placeholder column that holds no
  # cards invites the activity's first task (`＋ Add task`) instead of reading `— No task yet`.
  # It is NOT derivable from `last_of_activity?` — an activity with no tasks but WITH task-less
  # cards has a placeholder that is last AND occupied.
  defp no_task_column(activity, bare?) do
    %{
      key: "nt:#{activity.id}",
      activity: activity,
      task: nil,
      no_task?: true,
      bare?: bare?,
      draft?: false,
      merged?: false,
      collapsed?: false,
      task_count: 0,
      last_of_activity?: false,
      count: 0
    }
  end

  # RE263 — the open `{:task, _}` draft's column. It never receives cards (`fill/4` produces no
  # `"draft:"` key), so its body cells render empty; `mark_last/1` gives it `last_of_activity?`
  # because it is appended last.
  defp draft_column(activity) do
    %{
      key: "draft:#{activity.id}",
      activity: activity,
      task: nil,
      no_task?: false,
      bare?: false,
      draft?: true,
      merged?: false,
      collapsed?: false,
      task_count: 0,
      last_of_activity?: false,
      count: 0
    }
  end

  defp mark_last([]), do: []

  defp mark_last(columns) do
    {leading, [last]} = Enum.split(columns, -1)
    leading ++ [%{last | last_of_activity?: true}]
  end

  defp lane_list([]), do: [%{key: @none_lane_key, release: nil, count: 0}]
  defp lane_list(releases), do: Enum.map(releases, &%{key: "r:#{&1.id}", release: &1, count: 0})

  defp last_key(lanes), do: lanes |> List.last() |> Map.fetch!(:key)

  defp fill(placements, lane_keys, last_lane_key, hide_tasks?, collapsed) do
    {cells, unmapped, stub_counts} =
      Enum.reduce(placements, {%{}, [], %{}}, fn
        {:tray, card}, {cells, unmapped, stubs} ->
          {cells, [card | unmapped], stubs}

        {:grid, activity_id, task_id, card}, {cells, unmapped, stubs} ->
          if MapSet.member?(collapsed, activity_id) do
            # The third leg of the partition: the card renders nowhere, and the stub's badge
            # is the only thing that says how many are hidden.
            {cells, unmapped, Map.update(stubs, activity_id, 1, &(&1 + 1))}
          else
            key =
              {column_key(activity_id, task_id, hide_tasks?), lane_key(card, lane_keys, last_lane_key)}

            {Map.update(cells, key, [card], &[card | &1]), unmapped, stubs}
          end
      end)

    {Map.new(cells, fn {key, cards} -> {key, sort_cell(Enum.reverse(cards))} end), Enum.reverse(unmapped), stub_counts}
  end

  # RE262's sort rule, one line and total: `story_map_position` ascending, nils last, ties and
  # nils broken by the board order the cards arrived in. Enum.sort_by/2 is stable and Elixir's
  # term order puts every integer before `nil` (numbers sort before atoms), so positioned cards
  # come first in their chosen order and unpositioned cards keep Cards.list_cards/1's
  # (stage_id, position, id) order beneath them. No nil branch, no comparator. The TRAY is
  # deliberately not sorted: an unmapped card has no position by construction.
  defp sort_cell(cards), do: Enum.sort_by(cards, & &1.story_map_position)

  # RE260 — while merged, the activity IS the column: the artboard's `col.merged ||` short
  # circuit (line ~518) written as a key rule, so `fill/4` stays one pass and the invariant
  # holds without a second placement path.
  defp column_key(activity_id, _task_id, true), do: "m:#{activity_id}"
  defp column_key(activity_id, nil, _hide_tasks?), do: "nt:#{activity_id}"
  defp column_key(_activity_id, task_id, _hide_tasks?), do: "t:#{task_id}"

  # Rules 4–6: the card's release when the board has it, else the last lane. With zero releases
  # the synthetic `(No release)` lane IS the last lane, so nothing needs a special case.
  defp lane_key(card, lane_keys, last_lane_key) do
    key = card.release_id && "r:#{card.release_id}"
    if key && MapSet.member?(lane_keys, key), do: key, else: last_lane_key
  end

  # RE261 — the per-column tally was already computed inside count_bands/3 and thrown away;
  # exposing it is what lets a task's ✕ and its "Move N cards out" tooltip come from the SAME
  # numbers the band badge and the lane label show. One count, computed once, over exactly the
  # cards the grid renders — so "the header says 3" and "the ✕ is blocked" can never disagree.
  defp count_columns(columns, cells, stub_counts) do
    per_column = tally(cells, fn {column_key, _lane_key} -> column_key end)

    Enum.map(columns, fn
      %{collapsed?: true, activity: activity} = column ->
        %{column | count: Map.get(stub_counts, activity.id, 0)}

      column ->
        %{column | count: Map.get(per_column, column.key, 0)}
    end)
  end

  defp count_bands(bands, columns) do
    Enum.map(bands, fn band ->
      count = columns |> Enum.slice(band.start, band.span) |> Enum.reduce(0, &(&2 + &1.count))
      %{band | count: count}
    end)
  end

  defp count_lanes(lanes, cells) do
    per_lane = tally(cells, fn {_column_key, lane_key} -> lane_key end)
    Enum.map(lanes, &%{&1 | count: Map.get(per_lane, &1.key, 0)})
  end

  defp tally(cells, key_fun) do
    Enum.reduce(cells, %{}, fn {cell_key, cards}, acc ->
      Map.update(acc, key_fun.(cell_key), length(cards), &(&1 + length(cards)))
    end)
  end
end
