defmodule RelayWeb.StoryMapGrid do
  @moduledoc """
  The story map's pure view model (RE264): `(activities, tasks, releases, cards, draft)` in, a
  fully placed grid out. No Ecto, no LiveView, no side effects — every placement rule the
  artboard (`docs/designs/Relay Story Map.dc.html`, `eff/1`) encodes lives here, so the rules
  are unit-testable without mounting a LiveView.

  **The invariant: no card can disappear.** Every card handed to `build/5` lands exactly once —
  in one `cells` entry or in `unmapped` — and `total` is the input count. The rules are ordered
  and the last one is total:

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

  Keys are strings so they go straight into DOM ids: a task column is `"t:<task_id>"`, a
  no-task column `"nt:<activity_id>"`, a lane `"r:<release_id>"` or `"r:none"`.

  No `use Boundary` — a pure web-layer helper inside the `RelayWeb` boundary, like
  `RelayWeb.FlowLayout`.
  """

  @none_lane_key "r:none"

  defstruct bands: [], columns: [], lanes: [], cells: %{}, unmapped: [], total: 0

  @doc """
  Builds the grid. `activities`, `tasks` and `releases` are the board's structure in `position`
  order (`Relay.StoryMap.list_activities/1`, `list_tasks/1`, `list_releases/1`); `cards` is the
  board's non-archived cards in `Relay.Cards.list_cards/1` order, which every cell and the tray
  preserve.

  `draft` (RE263) is the page's open inline draft — `nil`, `:activity`, `:release`, or
  `{:task, activity_id}`. Only the last shape reaches the view model: it appends one draft
  column to that activity, growing its `span` by 1 and moving `last_of_activity?` onto it, and
  it **replaces** the placeholder column when the activity has neither tasks nor task-less
  cards. Everything else about the grid — placement, lanes, the tray, `total` — is unchanged,
  so the no-card-can-disappear invariant holds with a draft open.

  Fields of the returned struct:

    * `bands` — `[%{activity:, span:, count:, start:}]`, one per activity, left to right.
      `start` is the **0-based index into `columns`** of the band's first column; `span` how
      many columns it covers (always ≥ 1); `count` how many cards sit under it.
    * `columns` — `[%{key:, activity:, task:, no_task?:, bare?:, draft?:, last_of_activity?:}]`,
      left to right. `bare?` marks a `— No task yet` column that holds no cards, which the
      renderer turns into the clickable `＋ Add task` invitation (the artboard's `bare`);
      `draft?` marks RE263's open new-task column, whose key is `"draft:<activity_id>"` and
      which never appears in `cells`.
    * `lanes` — `[%{key:, release:, count:}]`, top to bottom. `release` is `nil` on the
      synthetic `(No release)` lane.
    * `cells` — `%{{column_key, lane_key} => [card]}`. A pair with no cards is simply absent.
    * `unmapped` — the tray's cards.
    * `total` — `length(cards)`.
  """
  def build(activities, tasks, releases, cards, draft \\ nil) do
    tasks_by_id = Map.new(tasks, &{&1.id, &1})
    activity_ids = MapSet.new(activities, & &1.id)
    tasks_by_activity = Enum.group_by(tasks, & &1.story_activity_id)

    placements = Enum.map(cards, &place(&1, tasks_by_id, activity_ids))

    no_task_ids =
      for {:grid, activity_id, nil, _card} <- placements, into: MapSet.new(), do: activity_id

    {columns, bands} =
      backbone(activities, tasks_by_activity, no_task_ids, draft_activity_id(draft))

    lanes = lane_list(releases)
    {cells, unmapped} = fill(placements, MapSet.new(lanes, & &1.key), last_key(lanes))

    %__MODULE__{
      bands: count_bands(bands, columns, cells),
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
  The DOM id of one body cell. `:` is not legal in a CSS selector, so the keys' colons become
  dashes — one definition, called by the renderer and by the tests that address a cell.
  """
  def cell_dom_id(column_key, lane_key), do: "story-map-cell-#{dash(column_key)}-#{dash(lane_key)}"

  defp dash(key), do: String.replace(key, ":", "-")

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

  defp backbone(activities, tasks_by_activity, no_task_ids, draft_activity_id) do
    {grouped, _next} =
      Enum.map_reduce(activities, 0, fn activity, start ->
        tasks = Map.get(tasks_by_activity, activity.id, [])
        draft? = activity.id == draft_activity_id
        no_task_cards? = MapSet.member?(no_task_ids, activity.id)

        # RE263 — the draft column stands in for the empty placeholder, so the user never sees
        # `＋ Add task` and an open input side by side. An activity that still holds task-less
        # CARDS keeps its `— No task yet` column: real cards live in it.
        no_task? = no_task_cards? or (tasks == [] and not draft?)

        columns =
          if(no_task?, do: [no_task_column(activity, not no_task_cards?)], else: []) ++
            Enum.map(tasks, &task_column(activity, &1)) ++
            if(draft?, do: [draft_column(activity)], else: [])

        columns = mark_last(columns)
        band = %{activity: activity, span: length(columns), count: 0, start: start}

        {{columns, band}, start + length(columns)}
      end)

    {Enum.flat_map(grouped, &elem(&1, 0)), Enum.map(grouped, &elem(&1, 1))}
  end

  defp task_column(activity, task) do
    %{
      key: "t:#{task.id}",
      activity: activity,
      task: task,
      no_task?: false,
      bare?: false,
      draft?: false,
      last_of_activity?: false
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
      last_of_activity?: false
    }
  end

  # RE263 — the open `{:task, _}` draft's column. It never receives cards (`fill/3` produces no
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
      last_of_activity?: false
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

  defp fill(placements, lane_keys, last_lane_key) do
    {cells, unmapped} =
      Enum.reduce(placements, {%{}, []}, fn
        {:tray, card}, {cells, unmapped} ->
          {cells, [card | unmapped]}

        {:grid, activity_id, task_id, card}, {cells, unmapped} ->
          key = {column_key(activity_id, task_id), lane_key(card, lane_keys, last_lane_key)}
          {Map.update(cells, key, [card], &[card | &1]), unmapped}
      end)

    {Map.new(cells, fn {key, cards} -> {key, Enum.reverse(cards)} end), Enum.reverse(unmapped)}
  end

  defp column_key(activity_id, nil), do: "nt:#{activity_id}"
  defp column_key(_activity_id, task_id), do: "t:#{task_id}"

  # Rules 4–6: the card's release when the board has it, else the last lane. With zero releases
  # the synthetic `(No release)` lane IS the last lane, so nothing needs a special case.
  defp lane_key(card, lane_keys, last_lane_key) do
    key = card.release_id && "r:#{card.release_id}"
    if key && MapSet.member?(lane_keys, key), do: key, else: last_lane_key
  end

  defp count_bands(bands, columns, cells) do
    per_column = tally(cells, fn {column_key, _lane_key} -> column_key end)

    Enum.map(bands, fn band ->
      count =
        columns
        |> Enum.slice(band.start, band.span)
        |> Enum.reduce(0, &(&2 + Map.get(per_column, &1.key, 0)))

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
