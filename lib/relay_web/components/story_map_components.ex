defmodule RelayWeb.StoryMapComponents do
  @moduledoc """
  The story map's rendering (RE264): pure function components over
  `RelayWeb.StoryMapGrid`'s view model, matching `docs/designs/Relay Story Map.dc.html`.

  Full zoom, **except** the affordances that are live: RE263's three create affordances — the
  trailing `＋` add-activity column, the `＋ Add task` on each activity header and on a bare
  placeholder, and the `＋ Release` row — which this module renders and `RelayWeb.BoardLive`
  handles; RE262's drag and drop (below); RE262's inline `＋` add-card in every cell (below); and
  RE261's structure editing — the `⠿` grip, the click-to-rename name and the `✕` delete on the
  activity band, the task column header and the release label. RE259 adds the FILTER bar
  (owner chips, the Needs-input toggle, the `Clear` link and the count label), the band's `▾`
  collapse and `◎` focus buttons, and the collapsed stub column; RE276 adds the `Hide complete`
  toggle beside `Needs input`, in the same chrome and pressed by default. The artboard's `✦`
  suggest button and its dashed `+ filter` button are still deliberately not rendered — the
  first is RE258, and the second is a filter-type PICKER, which this bar does not have: its
  filters are fixed controls, so `+ filter` would still open nothing.

  **Delete is blocked, not cascading (RE261).** A ✕ is `disabled` and greyed (the artboard's
  `delOff`) while its structure still holds cards, and its `title` names the exact count the
  header badge shows — both read from `RelayWeb.StoryMapGrid`'s `count`, so what the user is
  told and what the server enforces come from one number. The board's last remaining release
  renders no ✕ at all (the artboard's `canDelete: rels.length > 1`).

  **Two derivations the artboard needs and our data does not carry**, each written exactly once
  here (`card_face/4`) and used for both the badge and the card's tint:

    * the badge label — `:needs_input` → `NEEDS YOU`, a stalled run → `STALLED`, otherwise the
      card's stage name upcased, with the sub-task percentage appended as `CODE · 62%`;
    * the hue — the artboard's `statusHue` mapped onto `Schemas.Stage.category`: done → green,
      needs-input or stalled → amber, `:in_progress` → violet (the mock's PLAN/CODE/DEPLOY),
      `:planning` → blue (SPEC/REVIEW), otherwise neutral.

  The percentage itself is `Relay.Cards.sub_task_pct/1` — the same number `board_card/1` draws.

  **Drag and drop (RE262).** Every card face — cell and tray alike — is `draggable` and carries
  `.story-map-card[data-ref]`; every body cell is a `.story-map-drop[data-column][data-lane]`
  zone and the tray is `.story-map-drop-tray`. The hovered state is CSS
  (`.story-map-drop.drag-over` in `app.css`, the artboard's blue tint plus a 2px inset ring), not
  an assign — a hover never costs a round trip. `assets/js/hooks/story_map_dnd.js` reads exactly
  those four selectors and nothing else.

  RE257 adds `presence_stack/1`, the artboard's `showPresence` avatar stack. It is the only
  part of this module that is not a pure function of the board's data — it renders
  `Relay.Presence`'s live roster.
  """

  use Phoenix.Component

  alias Relay.Cards
  alias RelayWeb.CoreComponents
  alias RelayWeb.StoryMapFilter
  alias RelayWeb.StoryMapGrid

  # Artboard tokens (lines ~277-279): the grid lines and the two sticky header heights.
  @gl_light "1px solid var(--color-base-300)"
  @gl_strong "2px solid color-mix(in oklab, var(--color-base-content) 25%, var(--color-base-100))"
  @gl_dashed "1px dashed color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100))"
  @no_task_bg "var(--color-base-200)"
  @h1 56
  @h2 40

  # `Schemas.Release` carries no colour, so the swimlane dot comes from lane position: this is
  # pixel-exact for the three seeded releases (artboard lines ~242-246) and everything beyond
  # them — including the synthetic `(No release)` lane — takes the artboard's neutral dot.
  # RE237: the artboard's raw hue degrees (250, 195) become their theme tokens directly.
  @lane_dot_colors ["var(--color-primary)", "var(--color-accent)"]

  # RE260 — the ONE definition of the zoom closed set. `story_map_toolbar/1` renders its buttons
  # from this list and `parse_zoom/1` validates against it, so the control and the parser cannot
  # drift apart.
  @zoom_levels [:map, :compact, :full]

  # RE257 — the presence stack's artboard tokens (lines 49-56): 26px circles, five faces before
  # the +N chip, an 8px tuck between them (Tailwind `-ml-2`).
  @presence_size 26
  @presence_faces 5

  @doc """
  The zoom levels, in the artboard's left-to-right order (line ~44-46). The single source of
  truth for the closed set: the segmented control, the `attr :zoom` value lists and
  `parse_zoom/1` all derive from it.
  """
  def zoom_levels, do: @zoom_levels

  @doc """
  Parses a zoom level off the wire. Explicit clauses, never `String.to_atom/1` — this is client
  input, and an unknown value is `:error` rather than a new atom.

      parse_zoom("compact") #=> {:ok, :compact}
      parse_zoom("huge")    #=> :error
  """
  def parse_zoom("map"), do: {:ok, :map}
  def parse_zoom("compact"), do: {:ok, :compact}
  def parse_zoom("full"), do: {:ok, :full}
  def parse_zoom(_other), do: :error

  @doc """
  The card face's derived values — badge, hue, percentage, avatar and DOM id — for one card.
  Both the cell card and the tray card go through here, so the two derivations exist once.
  """
  def card_face(card, board, stages, stalled_ids) do
    stage = Enum.find(stages, &(&1.id == card.stage_id))
    ref = Cards.ref(board, card)
    done? = Cards.done?(card, stages)
    needs? = Cards.needs_input?(card)
    stalled? = MapSet.member?(stalled_ids, card.id)
    pct = Cards.sub_task_pct(card)

    %{
      id: "story-map-card-#{ref}",
      ref: ref,
      title: card.title,
      badge: badge(stage, needs?, stalled?, pct),
      hue: hue(stage, done?, needs?, stalled?),
      pct: pct,
      done: done?,
      avatar: avatar(done?, needs?),
      owners: card.owners,
      active_owner: Cards.active_owner_type(card)
    }
  end

  defp badge(stage, needs?, stalled?, pct) do
    label =
      cond do
        needs? -> "NEEDS YOU"
        stalled? -> "STALLED"
        is_nil(stage) -> ""
        true -> String.upcase(stage.name)
      end

    # `Cards.sub_task_pct/1` answers 0 for a checklist with nothing ticked — correct for the
    # drawer's bar, but the artboard treats 0 as absent (`stageText: c.pct ? … : c.stage`,
    # line ~385), so the badge stays bare here.
    if pct && pct > 0, do: "#{label} · #{pct}%", else: label
  end

  defp hue(stage, done?, needs?, stalled?) do
    cond do
      done? -> :green
      needs? or stalled? -> :amber
      match?(%{category: :in_progress}, stage) -> :violet
      match?(%{category: :planning}, stage) -> :blue
      true -> :neutral
    end
  end

  defp avatar(true, _needs?), do: :check
  defp avatar(_done?, true), do: :bang
  defp avatar(_done?, _needs?), do: :owners

  @doc """
  The top-chrome view controls (RE260, artboard lines ~42-48): the ZOOM segmented control and
  the Hide tasks toggle. Both are keys of the board-wide shared view
  (`Relay.StoryMap.view/1` plus `merge_view/2`, the one writer `put_view/3` and `toggle_view/2`
  compose) — they change the grid's geometry,
  which is the coordinate space RE257's raw-pixel cursors are measured in, so they are shared
  and persisted rather than per-socket. A click writes through the view and the buttons
  re-render from that write's own board-wide broadcast.

  The segments are rendered from `zoom_levels/0` and their event is parsed by `parse_zoom/1`,
  so a level can only ever be added in one place.
  """
  attr :zoom, :atom, values: @zoom_levels, required: true
  attr :hide_tasks, :boolean, required: true

  def story_map_toolbar(assigns) do
    assigns = assign(assigns, :levels, zoom_levels())

    ~H"""
    <div id="story-map-toolbar" style="display:flex;align-items:center;gap:10px;">
      <span style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);">
        ZOOM
      </span>
      <div
        id="story-map-zoom"
        role="group"
        aria-label="Zoom"
        style="display:flex;background:var(--color-field-hover);border-radius:8px;padding:3px;"
      >
        <button
          :for={level <- @levels}
          type="button"
          id={"story-map-zoom-#{level}"}
          phx-click="set_story_map_zoom"
          phx-value-zoom={level}
          aria-pressed={to_string(level == @zoom)}
          style={segment_style(level == @zoom)}
        >
          {zoom_label(level)}
        </button>
      </div>
      <button
        type="button"
        id="story-map-hide-tasks"
        phx-click="toggle_story_map_hide_tasks"
        aria-pressed={to_string(@hide_tasks)}
        style={hide_tasks_style(@hide_tasks)}
      >
        {hide_tasks_label(@hide_tasks)}
      </button>
    </div>
    """
  end

  @doc """
  The filter bar (RE259) — `docs/designs/Relay Story Map.dc.html` lines 60-76: a 48px-min row
  below the top chrome and above the map, carrying the mono `FILTER` label, the owner chip
  row, the `Needs input` toggle, the `◎ Focusing: <name> ✕` chip while focusing, the `Clear`
  link while a filter is active, and the mono count label.

  Every control is a key of the board-wide shared view, so a click writes through
  `Relay.StoryMap` and the bar re-renders from that write's own broadcast — the clicker
  included, exactly like ZOOM and Hide tasks above.

  Chips are drawn by `RelayWeb.CoreComponents.avatar/1`, the app's one definition of a
  person's circle, so a person looks the same here as in the member stack, the card owner
  cluster and RE257's presence stack — and the Relay AI chip is the standard violet mark
  rather than a hand-drawn initial. The selected chip's tint is that person's own
  `CoreComponents.identity_hue/1` at the artboard's fixed pale-tint lightness/chroma
  (`owner_chip_style/1` — RE237: stays OKLCH, not a token, same exception as
  `CoreComponents.identity_color/1`), so the artboard's per-person colour survives our real,
  unbounded roster.

  Two deliberate omissions from the artboard: the dashed `+ filter` button (line 69), which
  opens a filter-type PICKER this bar does not have — RE276's `Hide complete` is a second
  filter type, but it is a fixed control beside `Needs input` rather than something a picker
  adds, so the button would still open nothing — and the count label's ownership: it MOVED
  here from the app bar's `<:actions>` slot, keeping the DOM id `story-map-count` so existing
  selectors still resolve.

  `filter_active` is `Relay.StoryMap.filters_active?/1` — do the three filter keys differ from
  the board's DEFAULTS — and it drives the `Clear` link and nothing else. Collapse and focus
  narrow the view but are not "filters", and focus is exited at its own chip.

  **The count label deliberately does not read it** (RE276). The artboard's `countLabel` keyed
  off `filterActive`, which only worked while every filter defaulted to off; `hide_complete`
  defaults to ON, so a fresh board already hides cards. The rule is `<visible> of <total>`
  whenever `visible < total`, `<total> cards` otherwise — truthful whichever filter caused the
  gap.
  """
  attr :chips, :list, required: true, doc: "RelayWeb.StoryMapFilter.chips/2's shape"
  attr :needs_input, :boolean, required: true
  attr :hide_complete, :boolean, required: true
  attr :focus_name, :string, default: nil, doc: "the focused activity's name, or nil"
  attr :filter_active, :boolean, required: true
  attr :visible, :integer, required: true, doc: "cards passing the filter"
  attr :total, :integer, required: true, doc: "cards on the board"

  def story_map_filter_bar(assigns) do
    ~H"""
    <div id="story-map-filter-bar" style={filter_bar_style()}>
      <span style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
        FILTER
      </span>
      <span style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);margin-right:2px;">
        Owner
      </span>
      <button
        :for={chip <- @chips}
        type="button"
        id={StoryMapFilter.chip_dom_id(chip.key)}
        phx-click="toggle_story_map_owner_filter"
        phx-value-owner={chip.key}
        aria-pressed={to_string(chip.selected?)}
        aria-label={"Filter by #{chip.name}"}
        style={owner_chip_style(chip)}
      >
        <CoreComponents.avatar
          actor={chip.actor}
          src={chip.avatar_url}
          name={chip.name}
          email={chip.email}
          title={chip.name}
          size={20}
          tint={:identity}
          class={if(chip.selected?, do: nil, else: "opacity-[0.85]")}
        />
      </button>
      <span style="width:1px;height:20px;background:var(--color-field-border);margin:0 4px;"></span>
      <button
        type="button"
        id="story-map-needs-input-filter"
        phx-click="toggle_story_map_needs_filter"
        aria-pressed={to_string(@needs_input)}
        style={filter_toggle_style(@needs_input)}
      >
        <span style="width:6px;height:6px;border-radius:50%;background:var(--color-warning);"></span>
        Needs input
      </button>
      <button
        type="button"
        id="story-map-hide-complete-filter"
        phx-click="toggle_story_map_hide_complete"
        aria-pressed={to_string(@hide_complete)}
        style={filter_toggle_style(@hide_complete)}
      >
        Hide complete
      </button>
      <button
        :if={@focus_name}
        type="button"
        id="story-map-exit-focus"
        phx-click="clear_story_map_focus"
        style={focus_chip_style()}
      >
        ◎ Focusing: {@focus_name} ✕
      </button>
      <span style="flex:1;"></span>
      <button
        :if={@filter_active}
        type="button"
        id="story-map-clear-filters"
        phx-click="clear_story_map_filters"
        style="font-size:11px;font-weight:600;color:color-mix(in oklab, var(--color-primary) 85%, var(--color-base-content));"
      >
        Clear
      </button>
      <span
        id="story-map-count"
        style="font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);"
      >
        {count_label(@visible, @total)}
      </span>
    </div>
    """
  end

  # Artboard line 61.
  defp filter_bar_style do
    "min-height:48px;flex:0 0 auto;display:flex;align-items:center;gap:8px;flex-wrap:wrap;" <>
      "padding:9px 18px;border-bottom:#{@gl_light};background:var(--color-field-hover);z-index:55;"
  end

  # Artboard `ownerChips` (line ~542). The artboard's per-person `PEOPLE[init]` hue becomes
  # the app's own `identity_hue/1` — the ONE definition of who is what colour — and the AI
  # takes this module's violet, the same 292 degrees `--color-secondary` is defined at
  # (assets/css/app.css) — `chip_hue/1` is the one place that pins the number, since this
  # pale identity tint is deliberately not a role token.
  defp owner_chip_style(chip) do
    {background, border} =
      if chip.selected? do
        # Per-person/AI hue tint — no single brand role to map onto, the same exception
        # `CoreComponents.identity_color_for_hue/1` is granted, which is why the fill comes from
        # there rather than being re-typed here: L 0.62 is load-bearing (see its @doc) and must
        # hold in exactly one place. Only the HUE is exempt: freezing the LIGHTNESS too left a
        # near-white pill sitting on the dark filter bar. So the anchor is mixed into the surface
        # by Rule B, which reproduces the artboard's 0.95 fill / 0.75 border in light and a dark
        # tint of the same hue in dark: N = round5((1 - L) / (1 - 0.62) * 100) → 15 and 65.
        anchor = CoreComponents.identity_color_for_hue(chip_hue(chip))

        {"color-mix(in oklab, #{anchor} 15%, var(--color-base-100))",
         "color-mix(in oklab, #{anchor} 65%, var(--color-base-100))"}
      else
        {"var(--color-base-100)", "var(--color-field-border)"}
      end

    "display:flex;align-items:center;border-radius:8px;padding:3px;" <>
      "background:#{background};border:1px solid #{border};"
  end

  # 292 — `--color-secondary`'s hue (assets/css/app.css) — not `hue_role/1`'s vocabulary
  # below, which maps a status hue to a role *token*; this pins the raw degree the identity
  # tint above needs instead.
  defp chip_hue(%{actor: :ai}), do: 292
  defp chip_hue(%{email: email}), do: CoreComponents.identity_hue(email)

  # Artboard `needsStyle` (line ~572) — the filter bar's toggle chrome, shared by `Needs input`
  # and RE276's `Hide complete`. No artboard covers the second control, so it is built as a
  # SIBLING of the first and must stay indistinguishable from it: one function, two callers.
  defp filter_toggle_style(on?) do
    {background, color, border} =
      if on?,
        do:
          {"color-mix(in oklab, var(--color-warning) 15%, var(--color-base-100))",
           "color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content))",
           "color-mix(in oklab, var(--color-warning) 60%, var(--color-base-100))"},
        else:
          {"var(--color-base-100)", "color-mix(in oklab, var(--color-base-content) 70%, transparent)",
           "var(--color-field-border)"}

    "display:flex;align-items:center;gap:6px;border-radius:8px;padding:5px 10px;" <>
      "font-size:11.5px;font-weight:600;background:#{background};color:#{color};" <>
      "border:1px solid #{border};"
  end

  # Artboard line 71.
  defp focus_chip_style do
    "display:flex;align-items:center;gap:6px;border-radius:8px;padding:5px 10px;" <>
      "font-size:11.5px;font-weight:600;" <>
      "background:color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100));" <>
      "color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));" <>
      "border:1px solid color-mix(in oklab, var(--color-secondary) 25%, var(--color-base-100));"
  end

  # Artboard `countLabel` (line ~575), corrected by RE276. The artboard keyed this off
  # `filterActive`, which was only ever right while every filter defaulted to OFF: with
  # hide-complete defaulting to ON a fresh board already hides cards, so `<total> cards` would
  # be a lie on first paint for every board. The rule is now the two NUMBERS — truthful
  # whichever filter caused the gap, and `filter_active` is left to the `Clear` link alone.
  defp count_label(visible, total) when visible < total, do: "#{visible} of #{total}"
  defp count_label(_visible, total), do: "#{total} cards"

  @doc """
  A collapsed activity's stub column (RE259) — `docs/designs/Relay Story Map.dc.html` lines
  164-169 and the `topCells` stub branch (lines ~416-426): a 50px full-height column carrying
  the `▸` glyph, the activity name written vertically, and an **inverted** count badge (white
  on the neutral pill — the exact reverse of an expanded band's badge).

  It replaces the activity's band, its column headers and all of its body cells at once,
  spanning `grid-row:1 / -1`, which is why `RelayWeb.StoryMapGrid` emits **no band** for a
  collapsed activity.

  The click is the artboard's `onClick: st.focus ? setFocus : toggleCollapse` (line ~422):
  normally it expands this activity, and while focusing it moves the focus here instead —
  because expanding one activity in focus mode is exactly "focus that one".

  It is deliberately **not** a *card* drop target: it carries no `.story-map-drop` class, and
  `StoryMapGrid.decode_placement/2` has no `"c:"` clause, so a forged drop is refused server
  side too.

  It **is** still a RE261 header-reorder source and target (the artboard's stub carries
  `draggable` / `onDragStart` / `onDropAct`, template line ~165): it mirrors the band header's
  `.story-map-header` / `.story-map-header-drop` / `data-kind` / `data-id` wiring, which is what
  `StoryMapDnD` selects reorder by. Collapsing is a view state, and a shared board-wide one, so
  losing drag here would remove the affordance for every viewer. The two drag worlds stay apart
  in `dropZone/1`, so carrying the header classes never makes the stub take a card.
  """
  attr :activity, :any, required: true, doc: "the collapsed %Schemas.StoryActivity{}"
  attr :index, :integer, required: true, doc: "0-based index into the grid's columns"
  attr :count, :integer, required: true, doc: "how many of its cards are hidden"
  attr :focusing, :boolean, default: false
  attr :read_only, :boolean, default: false, doc: "an archived board reorders nothing"

  def story_map_collapsed_stub(assigns) do
    ~H"""
    <button
      type="button"
      id={"story-map-stub-#{@activity.id}"}
      class={[not @read_only && "story-map-header story-map-header-drop"]}
      data-kind="activity"
      data-id={@activity.id}
      draggable={to_string(not @read_only)}
      phx-click={if(@focusing, do: "set_story_map_focus", else: "toggle_story_map_collapse")}
      phx-value-activity-id={@activity.id}
      aria-label={if(@focusing, do: "Focus #{@activity.name}", else: "Expand #{@activity.name}")}
      style={stub_style(@index)}
    >
      <span style="font-size:12px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
        ▸
      </span>
      <span data-role="stub-name" style={stub_name_style()}>{@activity.name}</span>
      <span data-role="stub-count" style={inverted_count_style("2px 6px")}>{@count}</span>
    </button>
    """
  end

  # Artboard line ~419.
  defp stub_style(index) do
    "grid-column:#{index + 2};grid-row:1 / -1;align-self:stretch;position:sticky;top:0;" <>
      "z-index:22;background:var(--color-field-hover);border-right:#{@gl_strong};" <>
      "border-bottom:#{@gl_light};display:flex;flex-direction:column;align-items:center;" <>
      "justify-content:space-between;padding:10px 0;cursor:pointer;"
  end

  # Artboard line ~420.
  defp stub_name_style do
    "writing-mode:vertical-rl;transform:rotate(180deg);font-size:12px;font-weight:600;" <>
      "color:color-mix(in oklab, var(--color-base-content) 80%, transparent);"
  end

  @doc """
  The collaborator avatar stack (RE257) — `docs/designs/Relay Story Map.dc.html` lines 49-56,
  the artboard's `showPresence` mode: 26px identity-hued circles with a 2px white border, each
  after the first tucked -8px under its neighbour, capped at five faces with a neutral `+N` chip
  beyond.

  Renders **nothing when fewer than two people are present** — your own avatar alone is noise.
  You come first, with a `title` reading `"<name> (you)"`; everyone else follows in
  `Relay.Presence.list_people/1`'s roster order, which is the same for every viewer.

  Circles are drawn by `RelayWeb.CoreComponents.avatar/1` — the app's one definition of a
  person's circle — so a person looks the same here as in the member stack and the card owner
  cluster, and their cursor (`assets/js/hooks/story_map_cursors.js`) is the same colour because
  both read `CoreComponents.identity_color/1`.

  One deliberate deviation from the artboard: `avatar/1` sizes initials at
  `round(size * 0.42)` = 11px where the mockup hand-wrote 10px. Forking that ratio for one pixel
  would fork the app's avatar typography; size, fill, weight, colour, border and tuck all match.

  Placement is also a deliberate deviation (per the spec): the artboard puts this stack in the
  map's own toolbar beside ZOOM, and `BoardLive` renders it in the app layout's `<:actions>`
  slot beside the map's toolbar (RE259 moved `#story-map-count` down into the filter bar, its
  artboard home).
  """
  attr :people, :list, required: true, doc: "Relay.Presence.list_people/1's shape"
  attr :current_user_id, :integer, required: true

  def presence_stack(assigns) do
    {mine, others} = Enum.split_with(assigns.people, &(&1.user_id == assigns.current_user_id))
    ordered = mine ++ others
    shown = Enum.take(ordered, @presence_faces)

    assigns =
      assigns
      |> assign(:size, @presence_size)
      |> assign(:faces, shown |> Enum.map(&presence_face(&1, assigns.current_user_id)) |> Enum.with_index())
      |> assign(:overflow, length(ordered) - length(shown))

    ~H"""
    <div :if={length(@people) > 1} id="story-map-presence" style="display:flex;align-items:center;">
      <CoreComponents.avatar
        :for={{person, index} <- @faces}
        src={person.avatar_url}
        name={person.name}
        email={person.email}
        title={person.title}
        size={@size}
        tint={:identity}
        class={presence_avatar_class(index)}
      />
      <span :if={@overflow > 0} id="story-map-presence-overflow" style={presence_overflow_style()}>
        +{@overflow}
      </span>
    </div>
    """
  end

  defp presence_face(person, current_user_id) do
    label = person.name || person.email || ""

    Map.put(person, :title, if(person.user_id == current_user_id, do: "#{label} (you)", else: label))
  end

  # Artboard line ~51-53: `border:2px solid white` on every circle, `margin-left:-8px` on every
  # one after the first. Tailwind rather than inline style because `avatar/1` owns the style
  # attribute; `-ml-2` is 0.5rem = 8px, and `avatar/1`'s `box-sizing:border-box` matches the
  # artboard's own `*{box-sizing:border-box}` so 26px is the outer size in both.
  defp presence_avatar_class(0), do: "border-2 border-base-100"
  defp presence_avatar_class(_index), do: "border-2 border-base-100 -ml-2"

  # The artboard's mock has three faces and so shows no overflow chip. This borrows the board's
  # existing +N chip colours (`CoreComponents.member_stack/1`, `Relay Board.dc.html` ~1596) at
  # the presence stack's 26px, so the two stacks read as one system.
  defp presence_overflow_style do
    "width:#{@presence_size}px;height:#{@presence_size}px;border-radius:50%;" <>
      "background:var(--color-base-300);color:color-mix(in oklab, var(--color-base-content) 70%, transparent);display:flex;" <>
      "align-items:center;justify-content:center;font-size:10px;font-weight:600;" <>
      "flex:0 0 auto;box-sizing:border-box;border:2px solid var(--color-base-100);margin-left:-8px;"
  end

  @doc """
  The shared inline editor: one autofocused text input in a form, carrying the artboard's
  `inputStyle` (line ~404). Enter fires `submit`, every keystroke fires `change`, and Escape and
  clicking away both fire `cancel`.

  Clicking away is `phx-click-away`, and it is **forbidden** for it to be `phx-blur`. Blur is
  not a user gesture here: LiveView blurs this input itself, before it pushes the submit
  (`view.js` `submitForm` → `blurActiveElement`) and again around the patch that follows. Bound
  to `cancel`, those blurs land ahead of the submit, close the draft, and leave the submit with
  no draft to commit — Enter created NOTHING in every affordance, while `render_submit/2`,
  which never blurs, stayed green. `phx-click-away` fires only on a real click elsewhere, and
  LiveView dispatches it *before* that click's own `phx-click` (`live_socket.js` `bindClick`),
  so clicking a different ＋ still cancels this draft and then opens that one. The cost is that
  tabbing away no longer cancels — Escape and clicking away do. See
  `RelayWeb.Browser.StoryMapCreateTest`, which drives the real keypress.

  `change` is not optional bookkeeping — it is the same reason `BoardLive`'s composer has
  `validate_card` beside `create_card`: LiveView only patches an input whose *server-rendered*
  value changed, so without tracking the text the "commit clears and stays open" behaviour has
  nothing to diff against. The clearing itself is the `InlineNameInput` hook's job, because
  LiveView never patches a focused input's value at all.

  RE261 reuses this verbatim for rename — that reuse is why this is a component and not inline
  markup. `hook` exists so the storybook page can render it inert.
  """
  attr :id, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, default: ""
  attr :submit, :string, required: true, doc: "the phx-submit event name"
  attr :change, :string, required: true, doc: "the phx-change event name"
  attr :cancel, :string, required: true, doc: "the click-away AND Escape phx-keydown event name"
  attr :hook, :string, default: "InlineNameInput", doc: "nil renders the input without the hook"

  def inline_name_input(assigns) do
    ~H"""
    <.form
      for={%{}}
      id={"#{@id}-form"}
      phx-change={@change}
      phx-submit={@submit}
      style="display:flex;flex:1;min-width:0;"
    >
      <input
        type="text"
        id={@id}
        name="name"
        value={@value}
        placeholder={@placeholder}
        autocomplete="off"
        phx-hook={@hook}
        phx-click-away={@cancel}
        phx-keydown={@cancel}
        phx-key="Escape"
        style={input_style()}
      />
    </.form>
    """
  end

  # One header's name: the open rename input, or the resting name span. All three header shapes
  # go through here, so the rename event names and the `story-map-rename-<kind>-<id>` /
  # `story-map-name-<kind>-<id>` id conventions exist exactly once.
  #
  # On a read-only board the span renders WITHOUT `phx-click` and without `cursor:text` — the
  # name is still shown, it is just not an affordance (matching how `read_only` already
  # suppresses `＋ Add task`).
  attr :kind, :string, required: true, values: ~w(activity task release)
  attr :id, :integer, required: true
  attr :name, :string, required: true
  attr :editing, :boolean, required: true
  attr :edit_name, :string, required: true
  attr :read_only, :boolean, required: true
  attr :style, :string, required: true, doc: "the artboard's resting style for this name span"

  defp header_name(assigns) do
    ~H"""
    <.inline_name_input
      :if={@editing}
      id={"story-map-rename-#{@kind}-#{@id}"}
      value={@edit_name}
      submit="story_map_rename_submit"
      change="story_map_rename_change"
      cancel="story_map_rename_cancel"
    />
    <span
      :if={not @editing and not @read_only}
      id={"story-map-name-#{@kind}-#{@id}"}
      phx-click="story_map_rename_start"
      phx-value-kind={@kind}
      phx-value-id={@id}
      style={@style <> "cursor:text;"}
    >
      {@name}
    </span>
    <span :if={not @editing and @read_only} id={"story-map-name-#{@kind}-#{@id}"} style={@style}>
      {@name}
    </span>
    """
  end

  # The ✕. Greyed out and `disabled` while the structure still holds cards, with the artboard's
  # blocking tooltip naming the exact count the header badge shows.
  #
  # It is deliberately a `disabled` button rather than an enabled one that no-ops: `disabled` is
  # what makes the state real for a screen reader and for the acceptance test. The server refuses
  # a non-empty delete anyway (`{:error, :not_empty}`) — the two together are defence in depth.
  attr :kind, :string, required: true, values: ~w(activity task release)
  attr :id, :integer, required: true
  attr :count, :integer, required: true

  defp delete_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"story-map-delete-#{@kind}-#{@id}"}
      disabled={@count > 0}
      title={delete_title(@count, @kind)}
      phx-click="story_map_delete"
      phx-value-kind={@kind}
      phx-value-id={@id}
      style={delete_style(@count)}
    >
      ✕
    </button>
    """
  end

  # Artboard `blockMsg` (line ~403), verbatim — `card` singular at 1.
  defp delete_title(0, kind), do: "Delete #{kind}"
  defp delete_title(1, kind), do: "Move 1 card out of this #{kind} before deleting it"
  defp delete_title(count, kind), do: "Move #{count} cards out of this #{kind} before deleting it"

  # Artboard `delStyle` / `delOff`, lines ~397-398. The enabled label is `oklch 0.62 0.03 25` —
  # a warm grey, not a red: the artboard deliberately mutes this destructive affordance. C 0.03
  # sits in the gap between Rule N (chroma ≤ 0.02) and Rule B (worked at C ≥ 0.10), and Rule B's
  # ink formula cannot express it — solving `error` against `base-content` for L 0.62 needs ~100%
  # error, landing at C 0.16 and turning a muted link into bright coral. Rule N is the closer
  # translation (ΔC −0.03, L exact), so a near-neutral is treated as the neutral it nearly is.
  defp delete_style(0), do: "font-size:10px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"

  defp delete_style(_count),
    do: "font-size:10px;color:color-mix(in oklab, var(--color-base-content) 25%, transparent);cursor:not-allowed;"

  # The ⠿ drag handle. The activity header's is one step larger than the task header's (artboard
  # lines ~176 and ~198; the artboard also had it a touch darker, but Rule N collapses that 0.02 L
  # step so both now emit base-content 40%); the release label's — this card's addition, which the
  # artboard does not have — matches the task's.
  defp grip_style(:activity),
    do: "font-size:12px;color:color-mix(in oklab, var(--color-base-content) 40%, transparent);cursor:grab;"

  defp grip_style(_task_or_release),
    do: "font-size:11px;color:color-mix(in oklab, var(--color-base-content) 40%, transparent);cursor:grab;"

  @doc """
  The CSS grid: sticky corner, the two backing header bands, lane striping, the sticky release
  rail, the activity band, the task headers, and one body cell per column × lane.
  """
  attr :grid, :any, required: true, doc: "a %RelayWeb.StoryMapGrid{}"
  attr :board, :any, required: true, doc: "the board, for Relay.Cards.ref/2"
  attr :stages, :list, required: true, doc: "board.stages, for the badge and Cards.done?/2"
  attr :stalled_ids, :any, required: true, doc: "MapSet of card ids whose run is stalled"
  attr :draft, :any, default: nil, doc: "nil | :activity | :release | {:task, activity_id}"
  attr :draft_name, :string, default: "", doc: "the open draft's text, tracked server-side"
  attr :edit, :any, default: nil, doc: "nil | {:activity, id} | {:task, id} | {:release, id}"
  attr :edit_name, :string, default: "", doc: "the open rename's text, tracked server-side"
  attr :read_only, :boolean, default: false, doc: "hide mutating affordances when true"
  attr :compose, :any, default: nil, doc: "the {column_key, lane_key} whose composer is open, or nil"
  attr :compose_form, :any, default: nil, doc: "the shared card composer form (BoardLive's :compose_form)"
  attr :zoom, :atom, values: @zoom_levels, default: :full

  attr :focus, :any,
    default: nil,
    doc: "the focused %Schemas.StoryActivity{} (RelayWeb.StoryMapGrid.resolve_focus/2), or nil"

  def story_map(assigns) do
    ~H"""
    <div id="story-map-grid" style={grid_style(@grid, @draft)}>
      <div style={corner_style()}>
        <span style="font-family:var(--font-mono);font-size:9.5px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);">
          RELEASE ↓
        </span>
      </div>
      <%!-- The two sticky header backing bands (artboard lines ~427-428). The heights live in
            @h1/@h2, which are MODULE attributes — inside ~H a bare `@h1` would compile to
            `assigns.h1`, so they are only ever read from plain functions like this one. --%>
      <div style={band_backing(1)}></div>
      <div style={band_backing(2)}></div>
      <div
        :for={{_lane, index} <- Enum.with_index(@grid.lanes)}
        style={lane_stripe_style(index)}
        aria-hidden="true"
      >
      </div>
      <div
        :for={{lane, index} <- Enum.with_index(@grid.lanes)}
        id={lane_dom_id(lane)}
        class={[lane.release && not @read_only && "story-map-header story-map-header-drop"]}
        data-kind={lane.release && "release"}
        data-id={lane.release && lane.release.id}
        draggable={
          to_string(!!lane.release and not @read_only and @edit != {:release, lane.release.id})
        }
        style={lane_label_style(index)}
      >
        <div style="display:flex;align-items:center;gap:5px;">
          <span style={"width:8px;height:8px;border-radius:50%;background:#{lane_dot(index)};"}>
          </span>
          <span :if={lane.release && not @read_only} style={grip_style(:release)}>⠿</span>
          <%!-- The synthetic `(No release)` lane is not a structure: no grip, no rename, no ✕. --%>
          <span :if={is_nil(lane.release)} style={lane_name_style()}>{lane_name(lane)}</span>
          <.header_name
            :if={lane.release}
            kind="release"
            id={lane.release.id}
            name={lane_name(lane)}
            editing={@edit == {:release, lane.release.id}}
            edit_name={@edit_name}
            read_only={@read_only}
            style={lane_name_style() <> "flex:1;"}
          />
          <%!-- Artboard `canDelete: rels.length > 1` (line ~506): the board's LAST swimlane
                renders no ✕ at all. With zero releases the only lane is synthetic, so
                `length(@grid.lanes) > 1` is exactly "more than one real release". --%>
          <.delete_button
            :if={lane.release && not @read_only && length(@grid.lanes) > 1}
            kind="release"
            id={lane.release.id}
            count={lane.count}
          />
        </div>
        <span style="font-family:var(--font-mono);font-size:9px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);">
          {lane.count} cards
        </span>
      </div>
      <%!-- RE263 — the add-release row: a 44px grid row directly below the last swimlane
            label, in the sticky-left rail (artboard `addRelStyle`, line ~512 + lines ~152-155). --%>
      <div style={add_release_style(@grid)}>
        <button
          :if={@draft != :release and not @read_only}
          type="button"
          id="story-map-add-release"
          phx-click="story_map_add_release"
          style={add_release_button_style()}
        >
          ＋ Release
        </button>
        <.inline_name_input
          :if={@draft == :release}
          id="story-map-draft-input"
          placeholder="Release name… ↵"
          value={@draft_name}
          submit="story_map_draft_submit"
          change="story_map_draft_change"
          cancel="story_map_draft_cancel"
        />
      </div>
      <%!-- RE263 — the add-activity column: 58px pinned past the last band, widening to a task
            column's 156px while its draft is open (artboard `addActStyle`, line ~513). --%>
      <div style={add_activity_style(@grid, @draft)}>
        <button
          :if={@draft != :activity and not @read_only}
          type="button"
          id="story-map-add-activity"
          title="Add activity"
          phx-click="story_map_add_activity"
          style={add_activity_button_style()}
        >
          ＋
        </button>
        <.inline_name_input
          :if={@draft == :activity}
          id="story-map-draft-input"
          placeholder="Activity name… ↵"
          value={@draft_name}
          submit="story_map_draft_submit"
          change="story_map_draft_change"
          cancel="story_map_draft_cancel"
        />
      </div>
      <%!-- RE259 — a collapsed activity's stub stands in for its band, its column headers
            and its body cells, spanning grid-row 1 / -1. The grid emits no band for it, so
            nothing renders underneath. --%>
      <.story_map_collapsed_stub
        :for={{column, index} <- indexed_columns(@grid.columns, & &1.collapsed?)}
        activity={column.activity}
        index={index}
        count={column.count}
        focusing={@focus != nil}
        read_only={@read_only}
      />
      <div
        :for={band <- @grid.bands}
        id={"story-map-activity-#{band.activity.id}"}
        class={[not @read_only && "story-map-header story-map-header-drop"]}
        data-kind="activity"
        data-id={band.activity.id}
        draggable={to_string(not @read_only and @edit != {:activity, band.activity.id})}
        style={band_style(band)}
      >
        <div style="display:flex;align-items:center;gap:6px;">
          <span :if={not @read_only} style={grip_style(:activity)}>⠿</span>
          <.header_name
            kind="activity"
            id={band.activity.id}
            name={band.activity.name}
            editing={@edit == {:activity, band.activity.id}}
            edit_name={@edit_name}
            read_only={@read_only}
            style={activity_name_style()}
          />
        </div>
        <div style="display:flex;align-items:center;gap:6px;margin-top:4px;">
          <span style="font-family:var(--font-mono);font-size:9px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);background:var(--color-base-300);border-radius:20px;padding:2px 6px;">
            {band.count}
          </span>
          <span style="flex:1;"></span>
          <button
            :if={not @read_only}
            type="button"
            id={"story-map-add-task-#{band.activity.id}"}
            title="Add task"
            phx-click="story_map_add_task"
            phx-value-activity-id={band.activity.id}
            style={icon_style()}
          >
            ＋
          </button>
          <%!-- RE259 — ▾ collapses this band to a stub, ◎ focuses it (a collapse of everything
                else). Both render on a read-only board, like ZOOM and the tray: view state is not
                board data. The artboard puts ▾ in the name row (line ~174) and ◎ here (line ~188);
                both sit here so neither depends on the ⠿ grip, which read_only suppresses. --%>
          <button
            type="button"
            id={"story-map-collapse-#{band.activity.id}"}
            title="Collapse activity"
            phx-click="toggle_story_map_collapse"
            phx-value-activity-id={band.activity.id}
            style={icon_style()}
          >
            ▾
          </button>
          <button
            type="button"
            id={"story-map-focus-#{band.activity.id}"}
            title="Focus this activity"
            phx-click="set_story_map_focus"
            phx-value-activity-id={band.activity.id}
            style={icon_style()}
          >
            ◎
          </button>
          <.delete_button
            :if={not @read_only}
            kind="activity"
            id={band.activity.id}
            count={band.count}
          />
        </div>
      </div>
      <.story_map_column_header
        :for={{column, index} <- indexed_columns(@grid.columns, &(not &1.collapsed?))}
        column={column}
        index={index}
        draft_name={@draft_name}
        edit={@edit}
        edit_name={@edit_name}
        read_only={@read_only}
      />
      <%= for {column, ci} <- Enum.with_index(@grid.columns),
              not column.collapsed?,
              {lane, li} <- Enum.with_index(@grid.lanes) do %>
        <.story_map_cell
          column={column}
          lane={lane}
          column_index={ci}
          lane_index={li}
          cards={Map.get(@grid.cells, {column.key, lane.key}, [])}
          board={@board}
          stages={@stages}
          stalled_ids={@stalled_ids}
          composing={@compose == {column.key, lane.key}}
          compose_form={@compose_form}
          read_only={@read_only}
          zoom={@zoom}
        />
      <% end %>
    </div>
    """
  end

  @doc """
  One body cell (RE262): its cards, then either the dashed `＋` add button or the open
  composer. Extracted from `story_map/1` so that function stays pure layout and the composer
  has a unit to test and to storybook.

  Drop target: `.story-map-drop` + `data-column` / `data-lane` — `assets/js/hooks/story_map_dnd.js`
  reads exactly those three. The hovered state is CSS (`.story-map-drop.drag-over`), not an
  assign, so a hover never costs a round trip.

  `read_only` hides both the `＋` and the composer, the way `board_column/1` hides its own
  add-work button: an archived board's server-side guard already rejects `compose_cell` and
  `create_card_in_cell`, so rendering the affordance would only offer a dead button per cell.

  RE260 — `zoom` reaches here for exactly two things the artboard puts on the CELL rather than
  the card: the 3px/7px `gap` (line ~524) and the `＋`, which the artboard hides at Map only
  (`showAddBtn: z!=='map'`, line ~525). At Map the cards are one-line and a per-cell button
  would outweigh them; Compact and Full render it as today.
  """
  attr :column, :map, required: true, doc: "one entry of the grid's `columns`"
  attr :lane, :map, required: true, doc: "one entry of the grid's `lanes`"
  attr :cards, :list, required: true, doc: "this cell's cards, already sorted by StoryMapGrid"
  attr :board, :any, required: true
  attr :stages, :list, required: true
  attr :stalled_ids, :any, required: true
  attr :column_index, :integer, required: true, doc: "0-based, for grid-column"
  attr :lane_index, :integer, required: true, doc: "0-based, for grid-row"
  attr :composing, :boolean, default: false
  attr :compose_form, :any, default: nil, doc: "required when composing"
  attr :read_only, :boolean, default: false, doc: "hide mutating affordances when true"
  attr :zoom, :atom, values: @zoom_levels, default: :full

  def story_map_cell(assigns) do
    assigns =
      assign(assigns, :compose_id, StoryMapGrid.cell_element_id("compose", assigns.column.key, assigns.lane.key))

    ~H"""
    <div
      id={StoryMapGrid.cell_dom_id(@column.key, @lane.key)}
      class="story-map-drop"
      data-column={@column.key}
      data-lane={@lane.key}
      style={cell_style(@column, @column_index, @lane_index, @zoom)}
    >
      <.story_map_card
        :for={card <- @cards}
        zoom={@zoom}
        {card_face(card, @board, @stages, @stalled_ids)}
      />
      <.form
        :if={@composing and not @read_only}
        for={@compose_form}
        id={@compose_id}
        phx-change="validate_card"
        phx-submit="create_card_in_cell"
        phx-click-away="cancel_compose_cell"
        style="display:flex;align-items:center;gap:6px;background:var(--color-base-100);border:1.5px solid var(--color-primary);border-radius:9px;padding:7px 9px;"
      >
        <input type="hidden" name="column" value={@column.key} />
        <input type="hidden" name="lane" value={@lane.key} />
        <span style="color:var(--color-primary);font-size:14px;line-height:1;">+</span>
        <input
          type="text"
          id={@compose_id <> "-input"}
          name="card[title]"
          value={Phoenix.HTML.Form.normalize_value("text", @compose_form[:title].value)}
          placeholder="Add card… ↵"
          autofocus
          autocomplete="off"
          phx-keydown="cancel_compose_cell"
          phx-key="escape"
          style="border:none;outline:none;font-size:11.5px;width:100%;background:transparent;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"
        />
        <button
          type="button"
          id={@compose_id <> "-cancel"}
          phx-click="cancel_compose_cell"
          aria-label="Close the composer"
          style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
        >
          ✕
        </button>
      </.form>
      <button
        :if={not @composing and not @read_only and @zoom != :map}
        type="button"
        id={StoryMapGrid.cell_element_id("add", @column.key, @lane.key)}
        phx-click="compose_cell"
        phx-value-column={@column.key}
        phx-value-lane={@lane.key}
        aria-label="Add a card to this cell"
        style={add_button_style(@cards)}
      >
        ＋
      </button>
    </div>
    """
  end

  @doc """
  The cell card at one of the three zoom levels (RE260, the artboard's `cardVM`, lines ~366-388):

    * `:map` — a bare title line, the artboard's `lineStyle`: no box, a 2px hued left border and
      5px of left padding;
    * `:compact` — the non-`full` `boxStyle`: a white box with a 1px neutral border, a 3px hued
      left border, 6px radius and 6px/8px padding, title only;
    * `:full` — the `full` `boxStyle`, today's face unchanged: ref + owner avatar on the top row,
      the title, a mono stage badge, a 3px progress bar hugging the bottom edge and a
      status-tinted background/border.

  A done card is struck through and muted at Map, keeps its green left border at `opacity:0.82`
  at Compact, and at `opacity:0.8` at Full.

  **The zoom changes only what is RENDERED, never the element's contract**: at all three levels
  the article keeps `class="story-map-card"`, `data-ref`, `draggable="true"` and
  `phx-click="select_card"`, because `assets/js/hooks/story_map_dnd.js` keys off exactly that
  class and attribute and a card must never be a dead end. `card_face/4` is likewise unchanged —
  badge, hue, pct and avatar are derived identically at every zoom.

  `zoom` defaults to `:full` so every caller that predates RE260 — including the storybook
  variations — renders exactly what it rendered before.
  """
  attr :id, :string, required: true
  attr :ref, :string, required: true
  attr :title, :string, required: true
  attr :badge, :string, required: true

  attr :hue, :atom, values: [:green, :amber, :violet, :blue, :neutral], default: :neutral

  attr :pct, :integer, default: nil, doc: "sub-task completion; nil draws no bar"
  attr :done, :boolean, default: false
  attr :avatar, :atom, values: [:check, :bang, :owners], default: :owners
  attr :owners, :list, default: []
  attr :active_owner, :atom, values: [:human, :ai, nil], default: nil
  attr :zoom, :atom, values: @zoom_levels, default: :full

  def story_map_card(assigns) do
    ~H"""
    <article
      id={@id}
      class="story-map-card"
      style={card_shell(@zoom, @hue, @done)}
      role="button"
      tabindex="0"
      draggable="true"
      data-ref={@ref}
      data-hue={@hue}
      data-done={to_string(@done)}
      data-zoom={@zoom}
      phx-click="select_card"
      phx-value-ref={@ref}
    >
      <div :if={@zoom == :full} style="display:flex;align-items:center;justify-content:space-between;">
        <span style="font-family:var(--font-mono);font-size:9.5px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);">
          {@ref}
        </span>
        <.face_avatar avatar={@avatar} owners={@owners} active_owner={@active_owner} />
      </div>
      <span style={title_style(@zoom, @done)}>{@title}</span>
      <span :if={@zoom == :full} style={badge_style(@hue)}>{@badge}</span>
      <div
        :if={@zoom == :full and (@pct && @pct > 0)}
        class="story-map-card-bar"
        style={"position:absolute;left:0;bottom:0;height:3px;width:#{@pct}%;background:var(--color-secondary);"}
      >
      </div>
    </article>
    """
  end

  @doc """
  The UNMAPPED tray, both states: open (214px — label, count pill, the one-line helper and the
  scrolling card list) and collapsed (a 42px vertical rail keeping the chevron, count and
  label).

  It renders with an empty `cards` list too — count `0`, helper sentence, no cards. The tray is
  the only drop target that unmaps a card, so it is a permanent rail rather than a function of
  the list being non-empty (see the note at its call site in `BoardLive`).
  """
  attr :cards, :list, required: true
  attr :board, :any, required: true
  attr :stages, :list, required: true
  attr :stalled_ids, :any, required: true
  attr :open, :boolean, default: true

  def unmapped_tray(assigns) do
    ~H"""
    <div id="story-map-tray" class="story-map-drop-tray" style={tray_style(@open)}>
      <div :if={@open} style="display:flex;flex-direction:column;min-height:0;height:100%;">
        <button
          type="button"
          id="story-map-tray-toggle"
          phx-click="toggle_story_map_tray"
          aria-expanded="true"
          aria-label="Collapse the unmapped tray"
          style="display:flex;align-items:center;gap:8px;padding:11px 14px 9px;text-align:left;"
        >
          <span style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
            UNMAPPED
          </span>
          <span id="story-map-tray-count" style={inverted_count_style("2px 7px")}>
            {length(@cards)}
          </span>
          <span style="flex:1;"></span>
          <span style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
            ‹
          </span>
        </button>
        <div style="font-size:11px;line-height:1.35;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);padding:0 14px 10px;">
          No activity yet. Drag onto the map to place — or drop a card here to unmap it.
        </div>
        <div style="flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;gap:8px;padding:0 12px 14px;">
          <.tray_card
            :for={card <- @cards}
            face={card_face(card, @board, @stages, @stalled_ids)}
          />
        </div>
      </div>
      <button
        :if={not @open}
        type="button"
        id="story-map-tray-toggle"
        phx-click="toggle_story_map_tray"
        aria-expanded="false"
        aria-label="Expand the unmapped tray"
        style="height:100%;width:100%;display:flex;flex-direction:column;align-items:center;gap:10px;padding:12px 0;"
      >
        <span style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
          ›
        </span>
        <span id="story-map-tray-count" style={inverted_count_style("2px 6px")}>
          {length(@cards)}
        </span>
        <span style="writing-mode:vertical-rl;font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
          UNMAPPED
        </span>
      </button>
    </div>
    """
  end

  @doc """
  The day-one panel: what a board with zero activities shows, which every board is until
  someone creates the first one. The tray renders alongside it, so the page is never blank and
  no card is missing.

  It is also the empty board's *entry point*: the grid's trailing `＋` column only exists once
  the grid renders, so without the button here the first activity would be uncreatable. Opening
  the draft sets the same `:activity` assign the grid uses, and committing flips the render
  branch — the panel is replaced by the grid and the still-open draft reappears in the grid's
  trailing cell, unchanged.

  On a read-only (archived) board the button is not rendered, matching the stage column's
  `read_only` compose affordance.
  """
  attr :draft, :any, default: nil, doc: "nil | :activity | :release | {:task, activity_id}"
  attr :draft_name, :string, default: "", doc: "the open draft's text, tracked server-side"
  attr :read_only, :boolean, default: false, doc: "hide mutating affordances when true"

  def story_map_empty(assigns) do
    ~H"""
    <div
      id="story-map-empty"
      class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center"
    >
      <h2 style="font-size:15px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);">
        No story map yet
      </h2>
      <p
        class="max-w-md"
        style="font-size:12.5px;line-height:1.5;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);"
      >
        Activities and their Tasks form the backbone across the top; Releases are the swimlanes
        down the left, and your cards fill the grid where the two cross.
      </p>
      <button
        :if={@draft != :activity and not @read_only}
        type="button"
        id="story-map-empty-add-activity"
        class="btn btn-primary btn-sm"
        phx-click="story_map_add_activity"
      >
        Add your first activity
      </button>
      <div :if={@draft == :activity} style="display:flex;width:240px;">
        <.inline_name_input
          id="story-map-draft-input"
          placeholder="Activity name… ↵"
          value={@draft_name}
          submit="story_map_draft_submit"
          change="story_map_draft_change"
          cancel="story_map_draft_cancel"
        />
      </div>
    </div>
    """
  end

  # ---------- private renders ----------

  @doc """
  One column header, in all four shapes: RE263's open draft input, the bare `＋ Add task`
  invitation, a **real task column** (RE261's grip + click-to-rename name + ✕), and the plain
  `— No task yet` label.

  Only a real task column is a structure, so only it gets a grip, a rename and a ✕ — the bare
  placeholder keeps its shipped `＋ Add task` behaviour and the draft column is chrome. On a
  read-only board the bare column falls through to the plain label, so it keeps its place in
  the grid without inviting a click that only flashes an error.
  """
  attr :column, :map, required: true, doc: "one entry of the grid's `columns`"
  attr :index, :integer, required: true, doc: "0-based, for grid-column"
  attr :draft_name, :string, required: true
  attr :edit, :any, required: true, doc: "nil | {:activity, id} | {:task, id} | {:release, id}"
  attr :edit_name, :string, required: true
  attr :read_only, :boolean, required: true

  def story_map_column_header(assigns) do
    ~H"""
    <div
      :if={@column.merged?}
      id={column_dom_id(@column)}
      style={column_header_style(@column, @index)}
    >
      {column_name(@column)}
    </div>
    <div
      :if={@column.draft?}
      id={column_dom_id(@column)}
      style={column_header_style(@column, @index)}
    >
      <.inline_name_input
        id="story-map-draft-input"
        placeholder="Task name… ↵"
        value={@draft_name}
        submit="story_map_draft_submit"
        change="story_map_draft_change"
        cancel="story_map_draft_cancel"
      />
    </div>
    <button
      :if={not @column.draft? and @column.bare? and not @read_only}
      type="button"
      id={column_dom_id(@column)}
      phx-click="story_map_add_task"
      phx-value-activity-id={@column.activity.id}
      style={column_header_style(@column, @index)}
    >
      ＋ Add task
    </button>
    <div
      :if={not @column.draft? and not @column.merged? and not is_nil(@column.task)}
      id={column_dom_id(@column)}
      class={[not @read_only && "story-map-header story-map-header-drop"]}
      data-kind="task"
      data-id={@column.task && @column.task.id}
      draggable={to_string(not @read_only and @edit != {:task, @column.task && @column.task.id})}
      style={column_header_style(@column, @index)}
    >
      <span :if={not @read_only} style={grip_style(:task)}>⠿</span>
      <.header_name
        kind="task"
        id={@column.task && @column.task.id}
        name={column_name(@column)}
        editing={@edit == {:task, @column.task && @column.task.id}}
        edit_name={@edit_name}
        read_only={@read_only}
        style="flex:1;"
      />
      <.delete_button
        :if={not @read_only}
        kind="task"
        id={@column.task && @column.task.id}
        count={@column.count}
      />
    </div>
    <div
      :if={
        not @column.draft? and not @column.merged? and is_nil(@column.task) and
          (not @column.bare? or @read_only)
      }
      id={column_dom_id(@column)}
      style={column_header_style(@column, @index)}
    >
      {column_name(@column)}
    </div>
    """
  end

  attr :face, :map, required: true

  defp tray_card(assigns) do
    ~H"""
    <div
      id={"story-map-tray-card-#{@face.ref}"}
      class="story-map-tray-card story-map-card"
      role="button"
      tabindex="0"
      draggable="true"
      data-ref={@face.ref}
      phx-click="select_card"
      phx-value-ref={@face.ref}
      style={"flex:0 0 auto;background:var(--color-base-100);border:1px solid var(--color-field-border);border-left:3px solid #{card_accent(@face.hue, @face.done)};border-radius:8px;padding:8px 10px;display:flex;flex-direction:column;gap:7px;cursor:pointer;box-shadow:0 1px 2px color-mix(in oklab, var(--color-neutral) 7%, transparent);"}
    >
      <div style="display:flex;align-items:center;justify-content:space-between;">
        <span style="font-family:var(--font-mono);font-size:9.5px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);">
          {@face.ref}
        </span>
        <.face_avatar
          avatar={@face.avatar}
          owners={@face.owners}
          active_owner={@face.active_owner}
        />
      </div>
      <span style="font-size:12px;line-height:1.3;font-weight:500;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);">
        {@face.title}
      </span>
    </div>
    """
  end

  attr :avatar, :atom, required: true
  attr :owners, :list, required: true
  attr :active_owner, :atom, required: true

  defp face_avatar(assigns) do
    ~H"""
    <span
      :if={@avatar == :check}
      style={disc_style("var(--color-success)", "var(--color-success-content)")}
    >
      ✓
    </span>
    <span
      :if={@avatar == :bang}
      style={disc_style("var(--color-warning)", "var(--color-warning-content)")}
    >
      !
    </span>
    <CoreComponents.owner_avatars
      :if={@avatar == :owners}
      owners={@owners}
      active_owner={@active_owner}
      size={18}
    />
    """
  end

  defp disc_style(background, ink) do
    "width:18px;height:18px;border-radius:50%;background:#{background};color:#{ink};" <>
      "display:flex;align-items:center;justify-content:center;font-size:8px;font-weight:700;flex:0 0 auto;"
  end

  # ---------- private styles (artboard values, one definition each) ----------

  # Artboard `seg()` (line ~537): the active pill is white on the track, inactive is transparent.
  defp segment_style(active?) do
    {background, color} =
      if active?,
        do: {"var(--color-base-100)", "color-mix(in oklab, var(--color-base-content) 95%, transparent)"},
        else: {"transparent", "color-mix(in oklab, var(--color-base-content) 70%, transparent)"}

    "font-size:12px;font-weight:600;padding:4px 12px;border-radius:6px;" <>
      "color:#{color};background:#{background};"
  end

  defp zoom_label(:map), do: "Map"
  defp zoom_label(:compact), do: "Compact"
  defp zoom_label(:full), do: "Full"

  # Artboard `htBg` / `htFg` / `htBorder` (line ~569): violet while hiding, white while not.
  defp hide_tasks_style(true) do
    "font-size:12px;font-weight:600;padding:5px 11px;border-radius:8px;" <>
      "color:color-mix(in oklab, var(--color-secondary) 70%, var(--color-base-content));" <>
      "background:color-mix(in oklab, var(--color-secondary) 10%, var(--color-base-100));" <>
      "border:1px solid color-mix(in oklab, var(--color-secondary) 35%, var(--color-base-100));"
  end

  defp hide_tasks_style(_hiding) do
    "font-size:12px;font-weight:600;padding:5px 11px;border-radius:8px;" <>
      "color:color-mix(in oklab, var(--color-base-content) 75%, transparent);background:var(--color-base-100);" <>
      "border:1px solid var(--color-field-border);"
  end

  # Artboard `htLabel` (line ~568): the button says what the click will DO.
  defp hide_tasks_label(true), do: "Show tasks"
  defp hide_tasks_label(_hiding), do: "Hide tasks"

  # RE259 — HEEx's `:for` attribute accepts only a single generator (`pattern <- enumerable`),
  # not a comma-separated filter clause, so the stub loop and the header loop each narrow
  # `@grid.columns` through this helper rather than inline. `Enum.with_index/1` runs BEFORE the
  # filter, so `index` still names each column's true position in the full list — the same
  # position `grid_style/2` lays out in `grid-template-columns` — whether or not it survives
  # the filter.
  defp indexed_columns(columns, keep?) do
    columns |> Enum.with_index() |> Enum.filter(fn {column, _index} -> keep?.(column) end)
  end

  defp grid_style(grid, draft) do
    columns =
      Enum.map_join(grid.columns, " ", fn
        %{collapsed?: true} -> "50px"
        %{merged?: true} -> "176px"
        _column -> "156px"
      end)

    rows = Enum.map_join(grid.lanes, " ", fn _lane -> "auto" end)

    # RE263 — the artboard's `colTemplate` ends `' 58px'` (line ~492) and `rowsTemplate` ends
    # `' 44px'` (line ~493): the add-activity column and the add-release row. The trailing
    # column takes a task column's 156px while the activity draft is open, so there is room to
    # type; nothing else about the geometry moves.
    add_activity = if draft == :activity, do: "156px", else: "58px"

    "display:grid;grid-template-columns:128px #{columns} #{add_activity};" <>
      "grid-template-rows:#{@h1}px #{@h2}px #{rows} 44px;align-items:start;min-width:max-content;"
  end

  # Artboard `inputStyle`, line ~404.
  defp input_style do
    "flex:1;min-width:0;border:1.5px solid var(--color-primary);border-radius:5px;" <>
      "padding:2px 5px;font-size:12px;font-weight:600;outline:none;" <>
      "color:color-mix(in oklab, var(--color-base-content) 95%, transparent);background:var(--color-base-100);"
  end

  # Artboard `iconStyle`, line ~396.
  defp icon_style, do: "font-size:12px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"

  # Artboard `addActStyle`, line ~513. The COLUMN's width is `grid_style/2`'s business; this is
  # only the cell. The padding appears solely while the draft is open, so the resting state is
  # the artboard's verbatim.
  defp add_activity_style(grid, draft) do
    padding = if draft == :activity, do: "padding:0 8px;", else: ""

    "grid-column:#{length(grid.columns) + 2};grid-row:1 / span 2;position:sticky;top:0;" <>
      "z-index:22;background:var(--color-field-hover);border-bottom:#{@gl_light};" <>
      "display:flex;align-items:center;justify-content:center;#{padding}"
  end

  # Artboard line ~159.
  defp add_activity_button_style do
    "width:34px;height:34px;border-radius:9px;border:1px dashed color-mix(in oklab, var(--color-base-content) 25%, var(--color-base-100));" <>
      "color:color-mix(in oklab, var(--color-base-content) 65%, transparent);font-size:15px;line-height:1;background:var(--color-base-100);"
  end

  # Artboard `addRelStyle`, line ~512: the 44px row under the last swimlane label.
  defp add_release_style(grid) do
    "grid-column:1;grid-row:#{length(grid.lanes) + 3};position:sticky;left:0;z-index:16;" <>
      "background:var(--color-field-hover);border-right:#{@gl_strong};border-top:#{@gl_light};" <>
      "display:flex;align-items:center;padding:8px 12px;"
  end

  # Artboard line ~154.
  defp add_release_button_style do
    "display:flex;align-items:center;gap:6px;font-size:11.5px;font-weight:600;" <>
      "color:color-mix(in oklab, var(--color-base-content) 65%, transparent);border:1px dashed color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100));" <>
      "border-radius:8px;padding:4px 9px;width:100%;"
  end

  defp corner_style do
    "grid-column:1;grid-row:1 / span 2;position:sticky;top:0;left:0;z-index:35;" <>
      "background:var(--color-field-hover);border-right:#{@gl_strong};border-bottom:#{@gl_strong};" <>
      "display:flex;align-items:flex-end;padding:8px 12px;"
  end

  defp band_backing(1) do
    "grid-column:1 / -1;grid-row:1;position:sticky;top:0;z-index:8;background:var(--color-field-hover);"
  end

  defp band_backing(2) do
    "grid-column:1 / -1;grid-row:2;position:sticky;top:#{@h1}px;z-index:8;background:var(--color-field-hover);"
  end

  defp lane_stripe_style(index) do
    background = if rem(index, 2) == 1, do: "var(--color-field-hover)", else: "transparent"
    "grid-column:1 / -1;grid-row:#{index + 3};z-index:0;background:#{background};border-bottom:#{@gl_light};"
  end

  defp lane_label_style(index) do
    "grid-column:1;grid-row:#{index + 3};position:sticky;left:0;z-index:16;" <>
      "background:var(--color-field-hover);border-right:#{@gl_strong};display:flex;" <>
      "flex-direction:column;gap:5px;padding:8px 12px;"
  end

  defp lane_dot(index),
    do: Enum.at(@lane_dot_colors, index, "color-mix(in oklab, var(--color-base-content) 40%, var(--color-base-100))")

  # Artboard line ~141.
  defp lane_name_style,
    do: "font-size:12.5px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"

  defp lane_dom_id(%{release: nil}), do: "story-map-release-none"
  defp lane_dom_id(%{release: release}), do: "story-map-release-#{release.id}"

  defp lane_name(%{release: nil}), do: "(No release)"
  defp lane_name(%{release: release}), do: release.name

  # Artboard `nameStyle`, line ~431.
  defp activity_name_style,
    do: "font-size:13px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);"

  defp band_style(band) do
    "grid-column:#{band.start + 2} / span #{band.span};grid-row:1;align-self:stretch;" <>
      "position:sticky;top:0;z-index:22;background:var(--color-field-hover);" <>
      "border-right:#{@gl_strong};border-bottom:#{@gl_light};padding:8px 11px;" <>
      "display:flex;flex-direction:column;justify-content:center;"
  end

  # The ONE owner of every column's DOM id — the plan's contract, which the tests and the card's
  # acceptance criteria both address. All three column shapes are here, so the draft and the
  # bare `＋ Add task` header cannot drift from the plain label they replace.
  defp column_dom_id(%{merged?: true, activity: activity}), do: "story-map-merged-#{activity.id}"
  defp column_dom_id(%{draft?: true, activity: activity}), do: "story-map-draft-#{activity.id}"
  defp column_dom_id(%{no_task?: true, activity: activity}), do: "story-map-no-task-#{activity.id}"
  defp column_dom_id(%{task: task}), do: "story-map-task-#{task.id}"

  # Artboard line ~442: always the plural, even at 1 — and `0 tasks · merged` for an activity
  # with no tasks, which is the artboard's behaviour and left as is.
  defp column_name(%{merged?: true, task_count: count}), do: "#{count} tasks · merged"
  defp column_name(%{no_task?: true}), do: "— No task yet"
  defp column_name(%{task: task}), do: task.name

  # Artboard line ~443: the merged header is a LABEL — smaller, muted, no font-weight, no grip,
  # no rename, no drop target. It names an activity, not a task, so there is nothing to edit.
  defp column_header_style(%{merged?: true}, index) do
    "grid-column:#{index + 2};grid-row:2;position:sticky;top:#{@h1}px;z-index:20;" <>
      "background:var(--color-base-200);border-right:#{@gl_strong};border-bottom:#{@gl_strong};" <>
      "padding:7px 9px;font-size:10.5px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);" <>
      "display:flex;align-items:center;gap:6px;"
  end

  defp column_header_style(column, index) do
    {background, border_right, color} =
      if column.no_task? do
        # Artboard line ~456: `tasks.length ? '1px dashed …' : GL_STRONG` — when the activity has
        # no tasks at all this single column *is* the activity boundary, so it carries the strong
        # separator. (The body cell, artboard line ~524, is dashed unconditionally.)
        {@no_task_bg, if(column.last_of_activity?, do: @gl_strong, else: @gl_dashed),
         "color-mix(in oklab, var(--color-base-content) 55%, transparent)"}
      else
        {"var(--color-base-100)", if(column.last_of_activity?, do: @gl_strong, else: @gl_light),
         "color-mix(in oklab, var(--color-base-content) 85%, transparent)"}
      end

    # RE263 — the bare `＋ Add task` header is the one clickable column header (artboard line
    # ~457: `(bare ? 'cursor:pointer;' : '')`).
    cursor = if column.bare?, do: "cursor:pointer;", else: ""

    "grid-column:#{index + 2};grid-row:2;position:sticky;top:#{@h1}px;z-index:20;" <>
      "background:#{background};border-right:#{border_right};border-bottom:#{@gl_strong};" <>
      "padding:7px 9px;font-size:11.5px;font-weight:600;color:#{color};" <>
      "display:flex;align-items:center;gap:6px;#{cursor}"
  end

  defp cell_style(column, column_index, lane_index, zoom) do
    # RE263 — the draft column's body cells are empty and dashed, exactly like `— No task yet`.
    placeholder? = column.no_task? or column.draft?

    border_right =
      cond do
        placeholder? -> @gl_dashed
        column.last_of_activity? -> @gl_strong
        true -> @gl_light
      end

    background = if placeholder?, do: "background:#{@no_task_bg};", else: ""

    # Artboard line ~524: `gap:(z==='map'?'3px':'7px')`.
    gap = if zoom == :map, do: "3px", else: "7px"

    "grid-column:#{column_index + 2};grid-row:#{lane_index + 3};display:flex;" <>
      "flex-direction:column;gap:#{gap};padding:8px;min-height:26px;" <>
      "border-right:#{border_right};#{background}"
  end

  # Artboard `addBtnStyle` (line ~527): 7px of padding in an empty cell, 3px once it has cards —
  # the button shrinks out of the way rather than competing with the content.
  defp add_button_style(cards) do
    padding = if cards == [], do: "7px", else: "3px"

    "border:1px dashed color-mix(in oklab, var(--color-base-content) 15%, var(--color-base-100));border-radius:8px;padding:#{padding};" <>
      "color:color-mix(in oklab, var(--color-base-content) 40%, transparent);font-size:12px;line-height:1;"
  end

  # The artboard's `lineStyle` (cardVM, line ~379): Map zoom is a bare title line, not a box, so
  # the whole face is this ONE string and the title span adds no styling of its own.
  defp card_shell(:map, hue, done?) do
    strike =
      if done?,
        do:
          "text-decoration:line-through;text-decoration-color:color-mix(in oklab, var(--color-success) 65%, var(--color-base-100));",
        else: ""

    "font-size:9.5px;line-height:1.35;color:#{line_color(hue, done?)};" <>
      "border-left:2px solid #{line_accent(hue, done?)};padding-left:5px;cursor:grab;" <> strike
  end

  # The artboard's non-`full` `boxStyle` (line ~375): a white box with a hued left edge.
  defp card_shell(:compact, hue, done?) do
    fade = if done?, do: "opacity:0.82;", else: ""

    "background:var(--color-base-100);border:1px solid var(--color-base-300);" <>
      "border-left:3px solid #{card_accent(hue, done?)};border-radius:6px;padding:6px 8px;" <>
      "display:flex;flex-direction:column;cursor:grab;" <> fade
  end

  # The artboard's full-zoom `boxStyle` (cardVM, lines ~332-334). `cursor:grab` — RE262 makes
  # every card face draggable.
  defp card_shell(:full, _hue, true) do
    "background:color-mix(in oklab, var(--color-success) 10%, var(--color-base-100));" <>
      "border:1px solid color-mix(in oklab, var(--color-success) 30%, var(--color-base-100));border-radius:9px;" <>
      "padding:9px 10px;display:flex;flex-direction:column;gap:8px;" <>
      "box-shadow:0 1px 2.5px color-mix(in oklab, var(--color-neutral) 10%, transparent);position:relative;overflow:hidden;" <>
      "cursor:grab;opacity:0.8;border-left:3px solid var(--color-success);"
  end

  defp card_shell(:full, hue, _done) do
    {background, border} = tint(hue)

    "background:#{background};border:1px solid #{border};border-radius:9px;padding:9px 10px;" <>
      "display:flex;flex-direction:column;gap:8px;" <>
      "box-shadow:0 1px 2.5px color-mix(in oklab, var(--color-neutral) 10%, transparent);position:relative;overflow:hidden;" <>
      "cursor:grab;"
  end

  # Map zoom's text styling is part of the artboard's single `lineStyle` string, which
  # `card_shell(:map, …)` owns — so the title span renders with no style attribute at all
  # (`style={nil}` omits it). Compact and Full are the artboard's `titleStyle` (line ~380),
  # whose only zoom-dependent value is the size: `full ? '12.5px' : '11.5px'`.
  defp title_style(:map, _done?), do: nil

  defp title_style(zoom, done?) do
    size = if zoom == :full, do: "12.5px", else: "11.5px"

    "font-size:#{size};line-height:1.3;font-weight:500;color:#{title_color(done?)};"
  end

  # The ONE place a story-map status hue becomes its daisyUI role — RE237. `card_accent/2`,
  # `line_accent/2`, `line_color/2`, `tint/1` and `badge_colors/1` all key off this same
  # four-hue vocabulary; deriving each from here means adding or repointing a hue is a one-line
  # change instead of five.
  defp hue_role(:green), do: "success"
  defp hue_role(:amber), do: "warning"
  defp hue_role(:violet), do: "secondary"
  defp hue_role(:blue), do: "primary"

  defp role_token(hue), do: "var(--color-#{hue_role(hue)})"
  defp role_mix(hue, pct, base), do: "color-mix(in oklab, var(--color-#{hue_role(hue)}) #{pct}%, #{base})"

  # The hued left edge of a Compact box and of a tray card — the artboard's mid-tone hued fill,
  # green when done. `statusHue` never yields a neutral, so `:neutral` takes this module's own
  # neutral (chroma 0.02 at 255). RE237: the artboard's lightness sits in Rule B's mid-tone
  # bucket for every named hue, so each becomes its role token directly.
  defp card_accent(_hue, true), do: "var(--color-success)"
  defp card_accent(:neutral, _done?), do: "color-mix(in oklab, var(--color-base-content) 40%, var(--color-base-100))"
  defp card_accent(hue, _done?), do: role_token(hue)

  # Map zoom's 2px line border and its text colour (artboard `lineStyle`, line ~379).
  defp line_accent(_hue, true), do: "color-mix(in oklab, var(--color-success) 65%, var(--color-base-100))"

  defp line_accent(:neutral, _done?), do: "color-mix(in oklab, var(--color-base-content) 35%, var(--color-base-100))"

  defp line_accent(:green, _done?), do: role_mix(:green, 75, "var(--color-base-100)")
  defp line_accent(:amber, _done?), do: role_token(:amber)
  defp line_accent(:violet, _done?), do: role_mix(:violet, 70, "var(--color-base-100)")
  defp line_accent(:blue, _done?), do: role_mix(:blue, 75, "var(--color-base-100)")

  defp line_color(_hue, true), do: "color-mix(in oklab, var(--color-base-content) 65%, transparent)"
  defp line_color(:neutral, _done?), do: "color-mix(in oklab, var(--color-base-content) 75%, transparent)"
  defp line_color(:green, _done?), do: role_mix(:green, 40, "var(--color-base-content)")
  defp line_color(:amber, _done?), do: role_mix(:amber, 30, "var(--color-base-content)")
  defp line_color(:violet, _done?), do: role_mix(:violet, 45, "var(--color-base-content)")
  defp line_color(:blue, _done?), do: role_mix(:blue, 40, "var(--color-base-content)")

  defp tint(:green), do: {role_mix(:green, 10, "var(--color-base-100)"), role_mix(:green, 25, "var(--color-base-100)")}
  defp tint(:amber), do: {role_mix(:amber, 10, "var(--color-base-100)"), role_mix(:amber, 35, "var(--color-base-100)")}

  defp tint(:violet), do: {role_mix(:violet, 10, "var(--color-base-100)"), role_mix(:violet, 25, "var(--color-base-100)")}

  defp tint(:blue), do: {role_mix(:blue, 10, "var(--color-base-100)"), role_mix(:blue, 25, "var(--color-base-100)")}
  defp tint(:neutral), do: {"var(--color-field-hover)", "var(--color-base-300)"}

  defp title_color(true), do: "color-mix(in oklab, var(--color-base-content) 80%, transparent)"
  defp title_color(_done), do: "color-mix(in oklab, var(--color-base-content) 95%, transparent)"

  # The artboard's `stageColor` (lines ~299-304), keyed on the ONE hue instead of on the label.
  defp badge_colors(:green),
    do: {role_mix(:green, 15, "var(--color-base-100)"), role_mix(:green, 55, "var(--color-base-content)")}

  defp badge_colors(:amber),
    do: {role_mix(:amber, 15, "var(--color-base-100)"), role_mix(:amber, 55, "var(--color-base-content)")}

  defp badge_colors(:violet),
    do: {role_mix(:violet, 10, "var(--color-base-100)"), role_mix(:violet, 75, "var(--color-base-content)")}

  defp badge_colors(:blue),
    do: {role_mix(:blue, 15, "var(--color-base-100)"), role_mix(:blue, 60, "var(--color-base-content)")}

  defp badge_colors(:neutral),
    do: {"var(--color-base-300)", "color-mix(in oklab, var(--color-base-content) 70%, transparent)"}

  defp badge_style(hue) do
    {background, color} = badge_colors(hue)

    "font-family:var(--font-mono);font-size:8.5px;font-weight:600;letter-spacing:0.05em;" <>
      "padding:2px 5px;border-radius:4px;background:#{background};color:#{color};width:fit-content;"
  end

  defp tray_style(open) do
    width = if open, do: "214px", else: "42px"

    "flex:0 0 auto;width:#{width};border-right:2px solid color-mix(in oklab, var(--color-base-content) 15%, var(--color-base-100));" <>
      "background:var(--color-field-hover);z-index:50;overflow:hidden;"
  end

  # The inverted mono count pill: the surface colour as ink on a mid-grey fill. Shared by the
  # UNMAPPED tray's badge (artboard line ~87) and RE259's collapsed stub badge (line ~414),
  # which are the same pill at the same two paddings — so the tokens exist once.
  #
  # This is a Rule-N mid grey (P = 60), NOT the `--color-neutral` dark-band shortcut: that
  # shortcut is scoped to the 0.22 band, and taking it here dropped the pill 0.23 lightness in
  # light mode — ~9x Constraint 6's 0.025 tolerance.
  defp inverted_count_style(padding) do
    "font-family:var(--font-mono);font-size:9px;font-weight:600;color:var(--color-base-100);" <>
      "background:color-mix(in oklab, var(--color-base-content) 60%, var(--color-base-100));" <>
      "border-radius:20px;padding:#{padding};"
  end
end
