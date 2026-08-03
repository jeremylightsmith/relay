defmodule RelayWeb.StoryMapComponents do
  @moduledoc """
  The story map's rendering (RE264): pure function components over
  `RelayWeb.StoryMapGrid`'s view model, matching `docs/designs/Relay Story Map.dc.html`.

  Full zoom, **except** the affordances that are live: RE263's three create affordances — the
  trailing `＋` add-activity column, the `＋ Add task` on each activity header and on a bare
  placeholder, and the `＋ Release` row — which this module renders and `RelayWeb.BoardLive`
  handles; RE262's drag and drop (below); and RE262's inline `＋` add-card in every cell
  (below). The artboard's `⠿` grips, `▾` collapse, `✦` suggest, `◎` focus, `✎` rename, the `✕`
  deletes and the ZOOM/FILTER chrome are still deliberately not rendered — RE260/RE261 own
  them, and the filter bar's owner chips, Needs-input toggle and `+ filter` own no card today.

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
  """

  use Phoenix.Component

  alias Relay.Cards
  alias RelayWeb.CoreComponents
  alias RelayWeb.StoryMapGrid

  # Artboard tokens (lines ~277-279): the grid lines and the two sticky header heights.
  @gl_light "1px solid oklch(0.92 0.006 255)"
  @gl_strong "2px solid oklch(0.83 0.02 255)"
  @gl_dashed "1px dashed oklch(0.86 0.01 255)"
  @no_task_bg "oklch(0.978 0.004 255)"
  @h1 56
  @h2 40

  # `Schemas.Release` carries no colour, so the swimlane dot comes from lane position: this is
  # pixel-exact for the three seeded releases (artboard lines ~242-246) and everything beyond
  # them — including the synthetic `(No release)` lane — takes the artboard's neutral dot.
  @lane_hues [250, 195]

  @doc """
  The card face's derived values — badge, hue, percentage, avatar and DOM id — for one card.
  Both the cell card and the tray card go through here, so the two derivations exist once.
  """
  def card_face(card, board, stages, stalled_ids) do
    stage = Enum.find(stages, &(&1.id == card.stage_id))
    ref = Cards.ref(board, card)
    done? = Cards.done?(card, stages)
    needs? = card.status == :needs_input
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
  attr :read_only, :boolean, default: false, doc: "hide mutating affordances when true"
  attr :compose, :any, default: nil, doc: "the {column_key, lane_key} whose composer is open, or nil"
  attr :compose_form, :any, default: nil, doc: "the shared card composer form (BoardLive's :compose_form)"
  attr :read_only, :boolean, default: false, doc: "hide mutating affordances when true"

  def story_map(assigns) do
    ~H"""
    <div id="story-map-grid" style={grid_style(@grid, @draft)}>
      <div style={corner_style()}>
        <span style="font-family:var(--font-mono);font-size:9.5px;font-weight:600;letter-spacing:0.05em;color:oklch(0.55 0.02 255);">
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
        style={lane_label_style(index)}
      >
        <div style="display:flex;align-items:center;gap:5px;">
          <span style={"width:8px;height:8px;border-radius:50%;background:#{lane_dot(index)};"}>
          </span>
          <span style="font-size:12.5px;font-weight:600;color:oklch(0.3 0.02 255);">
            {lane_name(lane)}
          </span>
        </div>
        <span style="font-family:var(--font-mono);font-size:9px;color:oklch(0.6 0.02 255);">
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
      <div
        :for={band <- @grid.bands}
        id={"story-map-activity-#{band.activity.id}"}
        style={band_style(band)}
      >
        <span style="font-size:13px;font-weight:600;color:oklch(0.34 0.02 255);">
          {band.activity.name}
        </span>
        <div style="display:flex;align-items:center;gap:6px;margin-top:4px;">
          <span style="font-family:var(--font-mono);font-size:9px;font-weight:600;color:oklch(0.5 0.02 255);background:oklch(0.93 0.006 255);border-radius:20px;padding:2px 6px;">
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
        </div>
      </div>
      <.column_header
        :for={{column, index} <- Enum.with_index(@grid.columns)}
        column={column}
        index={index}
        draft_name={@draft_name}
        read_only={@read_only}
      />
      <%= for {column, ci} <- Enum.with_index(@grid.columns), {lane, li} <- Enum.with_index(@grid.lanes) do %>
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

  def story_map_cell(assigns) do
    assigns =
      assign(assigns, :compose_id, StoryMapGrid.cell_element_id("compose", assigns.column.key, assigns.lane.key))

    ~H"""
    <div
      id={StoryMapGrid.cell_dom_id(@column.key, @lane.key)}
      class="story-map-drop"
      data-column={@column.key}
      data-lane={@lane.key}
      style={cell_style(@column, @column_index, @lane_index)}
    >
      <.story_map_card
        :for={card <- @cards}
        {card_face(card, @board, @stages, @stalled_ids)}
      />
      <.form
        :if={@composing and not @read_only}
        for={@compose_form}
        id={@compose_id}
        phx-change="validate_card"
        phx-submit="create_card_in_cell"
        phx-click-away="cancel_compose_cell"
        style="display:flex;align-items:center;gap:6px;background:oklch(1 0 0);border:1.5px solid oklch(0.6 0.14 250);border-radius:9px;padding:7px 9px;"
      >
        <input type="hidden" name="column" value={@column.key} />
        <input type="hidden" name="lane" value={@lane.key} />
        <span style="color:oklch(0.6 0.14 250);font-size:14px;line-height:1;">+</span>
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
          style="border:none;outline:none;font-size:11.5px;width:100%;background:transparent;color:oklch(0.3 0.02 255);"
        />
        <button
          type="button"
          id={@compose_id <> "-cancel"}
          phx-click="cancel_compose_cell"
          aria-label="Close the composer"
          style="font-size:11px;color:oklch(0.6 0.02 255);"
        >
          ✕
        </button>
      </.form>
      <button
        :if={not @composing and not @read_only}
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
  The full-zoom cell card: ref + owner avatar on the top row, the title, a mono stage badge, a
  3px progress bar hugging the bottom edge, and a status-tinted background/border. A done card
  gets the green left border and reduced opacity.
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

  def story_map_card(assigns) do
    ~H"""
    <article
      id={@id}
      class="story-map-card"
      style={card_shell(@hue, @done)}
      role="button"
      tabindex="0"
      draggable="true"
      data-ref={@ref}
      data-hue={@hue}
      data-done={to_string(@done)}
      phx-click="select_card"
      phx-value-ref={@ref}
    >
      <div style="display:flex;align-items:center;justify-content:space-between;">
        <span style="font-family:var(--font-mono);font-size:9.5px;color:oklch(0.55 0.02 255);">
          {@ref}
        </span>
        <.face_avatar avatar={@avatar} owners={@owners} active_owner={@active_owner} />
      </div>
      <span style={"font-size:12.5px;line-height:1.3;font-weight:500;color:#{title_color(@done)};"}>
        {@title}
      </span>
      <span style={badge_style(@hue)}>{@badge}</span>
      <div
        :if={@pct && @pct > 0}
        class="story-map-card-bar"
        style={"position:absolute;left:0;bottom:0;height:3px;width:#{@pct}%;background:oklch(0.56 0.16 292);"}
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
          <span style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.5 0.02 255);">
            UNMAPPED
          </span>
          <span id="story-map-tray-count" style={tray_count_style("2px 7px")}>{length(@cards)}</span>
          <span style="flex:1;"></span>
          <span style="font-size:11px;color:oklch(0.5 0.02 255);">‹</span>
        </button>
        <div style="font-size:11px;line-height:1.35;color:oklch(0.55 0.02 255);padding:0 14px 10px;">
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
        <span style="font-size:11px;color:oklch(0.5 0.02 255);">›</span>
        <span id="story-map-tray-count" style={tray_count_style("2px 6px")}>{length(@cards)}</span>
        <span style="writing-mode:vertical-rl;font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.5 0.02 255);">
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
      <h2 style="font-size:15px;font-weight:600;color:oklch(0.34 0.02 255);">
        No story map yet
      </h2>
      <p class="max-w-md" style="font-size:12.5px;line-height:1.5;color:oklch(0.5 0.02 255);">
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

  # RE263 — row 2 now has three shapes: the open draft's input; the `＋ Add task` invitation on
  # an activity that has neither tasks nor task-less cards (artboard `bare = !ntCount`, line
  # ~450), which is a real button because the WHOLE header is clickable; and a plain label for
  # everything else. On a read-only board the bare column takes the plain-label branch, so it
  # keeps its place in the grid without inviting a click that only flashes an error.
  attr :column, :map, required: true
  attr :index, :integer, required: true
  attr :draft_name, :string, required: true
  attr :read_only, :boolean, required: true

  defp column_header(assigns) do
    ~H"""
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
      :if={not @column.draft? and (not @column.bare? or @read_only)}
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
      style={"flex:0 0 auto;background:oklch(1 0 0);border:1px solid oklch(0.9 0.006 255);border-left:3px solid #{tray_accent(@face)};border-radius:8px;padding:8px 10px;display:flex;flex-direction:column;gap:7px;cursor:pointer;box-shadow:0 1px 2px oklch(0.4 0.05 260/0.07);"}
    >
      <div style="display:flex;align-items:center;justify-content:space-between;">
        <span style="font-family:var(--font-mono);font-size:9.5px;color:oklch(0.55 0.02 255);">
          {@face.ref}
        </span>
        <.face_avatar
          avatar={@face.avatar}
          owners={@face.owners}
          active_owner={@face.active_owner}
        />
      </div>
      <span style="font-size:12px;line-height:1.3;font-weight:500;color:oklch(0.28 0.02 255);">
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
    <span :if={@avatar == :check} style={disc_style("oklch(0.6 0.13 155)")}>✓</span>
    <span :if={@avatar == :bang} style={disc_style("oklch(0.72 0.13 65)")}>!</span>
    <CoreComponents.owner_avatars
      :if={@avatar == :owners}
      owners={@owners}
      active_owner={@active_owner}
      size={18}
    />
    """
  end

  defp disc_style(background) do
    "width:18px;height:18px;border-radius:50%;background:#{background};color:oklch(1 0 0);" <>
      "display:flex;align-items:center;justify-content:center;font-size:8px;font-weight:700;flex:0 0 auto;"
  end

  # ---------- private styles (artboard values, one definition each) ----------

  defp grid_style(grid, draft) do
    columns = Enum.map_join(grid.columns, " ", fn _column -> "156px" end)
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
    "flex:1;min-width:0;border:1.5px solid oklch(0.6 0.14 250);border-radius:5px;" <>
      "padding:2px 5px;font-size:12px;font-weight:600;outline:none;" <>
      "color:oklch(0.3 0.02 255);background:white;"
  end

  # Artboard `iconStyle`, line ~396.
  defp icon_style, do: "font-size:12px;color:oklch(0.55 0.02 255);"

  # Artboard `addActStyle`, line ~513. The COLUMN's width is `grid_style/2`'s business; this is
  # only the cell. The padding appears solely while the draft is open, so the resting state is
  # the artboard's verbatim.
  defp add_activity_style(grid, draft) do
    padding = if draft == :activity, do: "padding:0 8px;", else: ""

    "grid-column:#{length(grid.columns) + 2};grid-row:1 / span 2;position:sticky;top:0;" <>
      "z-index:22;background:oklch(0.965 0.006 255);border-bottom:#{@gl_light};" <>
      "display:flex;align-items:center;justify-content:center;#{padding}"
  end

  # Artboard line ~159.
  defp add_activity_button_style do
    "width:34px;height:34px;border-radius:9px;border:1px dashed oklch(0.82 0.01 255);" <>
      "color:oklch(0.55 0.02 255);font-size:15px;line-height:1;background:white;"
  end

  # Artboard `addRelStyle`, line ~512: the 44px row under the last swimlane label.
  defp add_release_style(grid) do
    "grid-column:1;grid-row:#{length(grid.lanes) + 3};position:sticky;left:0;z-index:16;" <>
      "background:oklch(0.96 0.006 255);border-right:#{@gl_strong};border-top:#{@gl_light};" <>
      "display:flex;align-items:center;padding:8px 12px;"
  end

  # Artboard line ~154.
  defp add_release_button_style do
    "display:flex;align-items:center;gap:6px;font-size:11.5px;font-weight:600;" <>
      "color:oklch(0.55 0.02 255);border:1px dashed oklch(0.85 0.008 255);" <>
      "border-radius:8px;padding:4px 9px;width:100%;"
  end

  defp corner_style do
    "grid-column:1;grid-row:1 / span 2;position:sticky;top:0;left:0;z-index:35;" <>
      "background:oklch(0.96 0.006 255);border-right:#{@gl_strong};border-bottom:#{@gl_strong};" <>
      "display:flex;align-items:flex-end;padding:8px 12px;"
  end

  defp band_backing(1) do
    "grid-column:1 / -1;grid-row:1;position:sticky;top:0;z-index:8;background:oklch(0.96 0.006 255);"
  end

  defp band_backing(2) do
    "grid-column:1 / -1;grid-row:2;position:sticky;top:#{@h1}px;z-index:8;background:oklch(0.965 0.005 255);"
  end

  defp lane_stripe_style(index) do
    background = if rem(index, 2) == 1, do: "oklch(0.975 0.004 255)", else: "transparent"
    "grid-column:1 / -1;grid-row:#{index + 3};z-index:0;background:#{background};border-bottom:#{@gl_light};"
  end

  defp lane_label_style(index) do
    "grid-column:1;grid-row:#{index + 3};position:sticky;left:0;z-index:16;" <>
      "background:oklch(0.96 0.006 255);border-right:#{@gl_strong};display:flex;" <>
      "flex-direction:column;gap:5px;padding:8px 12px;"
  end

  defp lane_dot(index) do
    case Enum.at(@lane_hues, index) do
      nil -> "oklch(0.7 0.02 255)"
      hue -> "oklch(0.6 0.13 #{hue})"
    end
  end

  defp lane_dom_id(%{release: nil}), do: "story-map-release-none"
  defp lane_dom_id(%{release: release}), do: "story-map-release-#{release.id}"

  defp lane_name(%{release: nil}), do: "(No release)"
  defp lane_name(%{release: release}), do: release.name

  defp band_style(band) do
    "grid-column:#{band.start + 2} / span #{band.span};grid-row:1;align-self:stretch;" <>
      "position:sticky;top:0;z-index:22;background:oklch(0.972 0.006 255);" <>
      "border-right:#{@gl_strong};border-bottom:#{@gl_light};padding:8px 11px;" <>
      "display:flex;flex-direction:column;justify-content:center;"
  end

  # The ONE owner of every column's DOM id — the plan's contract, which the tests and the card's
  # acceptance criteria both address. All three column shapes are here, so the draft and the
  # bare `＋ Add task` header cannot drift from the plain label they replace.
  defp column_dom_id(%{draft?: true, activity: activity}), do: "story-map-draft-#{activity.id}"
  defp column_dom_id(%{no_task?: true, activity: activity}), do: "story-map-no-task-#{activity.id}"
  defp column_dom_id(%{task: task}), do: "story-map-task-#{task.id}"

  defp column_name(%{no_task?: true}), do: "— No task yet"
  defp column_name(%{task: task}), do: task.name

  defp column_header_style(column, index) do
    {background, border_right, color} =
      if column.no_task? do
        # Artboard line ~456: `tasks.length ? '1px dashed …' : GL_STRONG` — when the activity has
        # no tasks at all this single column *is* the activity boundary, so it carries the strong
        # separator. (The body cell, artboard line ~524, is dashed unconditionally.)
        {@no_task_bg, if(column.last_of_activity?, do: @gl_strong, else: @gl_dashed), "oklch(0.58 0.02 255)"}
      else
        {"oklch(1 0 0)", if(column.last_of_activity?, do: @gl_strong, else: @gl_light), "oklch(0.36 0.02 255)"}
      end

    # RE263 — the bare `＋ Add task` header is the one clickable column header (artboard line
    # ~457: `(bare ? 'cursor:pointer;' : '')`).
    cursor = if column.bare?, do: "cursor:pointer;", else: ""

    "grid-column:#{index + 2};grid-row:2;position:sticky;top:#{@h1}px;z-index:20;" <>
      "background:#{background};border-right:#{border_right};border-bottom:#{@gl_strong};" <>
      "padding:7px 9px;font-size:11.5px;font-weight:600;color:#{color};" <>
      "display:flex;align-items:center;gap:6px;#{cursor}"
  end

  defp cell_style(column, column_index, lane_index) do
    # RE263 — the draft column's body cells are empty and dashed, exactly like `— No task yet`.
    placeholder? = column.no_task? or column.draft?

    border_right =
      cond do
        placeholder? -> @gl_dashed
        column.last_of_activity? -> @gl_strong
        true -> @gl_light
      end

    background = if placeholder?, do: "background:#{@no_task_bg};", else: ""

    "grid-column:#{column_index + 2};grid-row:#{lane_index + 3};display:flex;" <>
      "flex-direction:column;gap:7px;padding:8px;min-height:26px;" <>
      "border-right:#{border_right};#{background}"
  end

  # Artboard `addBtnStyle` (line ~527): 7px of padding in an empty cell, 3px once it has cards —
  # the button shrinks out of the way rather than competing with the content.
  defp add_button_style(cards) do
    padding = if cards == [], do: "7px", else: "3px"

    "border:1px dashed oklch(0.88 0.008 255);border-radius:8px;padding:#{padding};" <>
      "color:oklch(0.72 0.02 255);font-size:12px;line-height:1;"
  end

  # The artboard's full-zoom `boxStyle` (cardVM, lines ~332-334). `cursor:grab` — RE262 makes
  # every card face draggable.
  defp card_shell(_hue, true) do
    "background:oklch(0.97 0.015 150);border:1px solid oklch(0.88 0.04 150);border-radius:9px;" <>
      "padding:9px 10px;display:flex;flex-direction:column;gap:8px;" <>
      "box-shadow:0 1px 2.5px oklch(0.4 0.05 260/0.1);position:relative;overflow:hidden;" <>
      "cursor:grab;opacity:0.8;border-left:3px solid oklch(0.6 0.13 155);"
  end

  defp card_shell(hue, _done) do
    {background, border} = tint(hue)

    "background:#{background};border:1px solid #{border};border-radius:9px;padding:9px 10px;" <>
      "display:flex;flex-direction:column;gap:8px;" <>
      "box-shadow:0 1px 2.5px oklch(0.4 0.05 260/0.1);position:relative;overflow:hidden;" <>
      "cursor:grab;"
  end

  defp tint(:green), do: {"oklch(0.965 0.028 155)", "oklch(0.9 0.04 155)"}
  defp tint(:amber), do: {"oklch(0.965 0.028 65)", "oklch(0.9 0.04 65)"}
  defp tint(:violet), do: {"oklch(0.965 0.028 292)", "oklch(0.9 0.04 292)"}
  defp tint(:blue), do: {"oklch(0.965 0.028 250)", "oklch(0.9 0.04 250)"}
  defp tint(:neutral), do: {"oklch(0.97 0.006 255)", "oklch(0.92 0.006 255)"}

  defp title_color(true), do: "oklch(0.4 0.02 255)"
  defp title_color(_done), do: "oklch(0.28 0.02 255)"

  # The artboard's `stageColor` (lines ~299-304), keyed on the ONE hue instead of on the label.
  defp badge_colors(:green), do: {"oklch(0.94 0.04 155)", "oklch(0.44 0.11 155)"}
  defp badge_colors(:amber), do: {"oklch(0.96 0.05 65)", "oklch(0.5 0.13 65)"}
  defp badge_colors(:violet), do: {"oklch(0.95 0.035 292)", "oklch(0.48 0.14 292)"}
  defp badge_colors(:blue), do: {"oklch(0.95 0.03 250)", "oklch(0.46 0.12 250)"}
  defp badge_colors(:neutral), do: {"oklch(0.94 0.006 255)", "oklch(0.5 0.02 255)"}

  defp badge_style(hue) do
    {background, color} = badge_colors(hue)

    "font-family:var(--font-mono);font-size:8.5px;font-weight:600;letter-spacing:0.05em;" <>
      "padding:2px 5px;border-radius:4px;background:#{background};color:#{color};width:fit-content;"
  end

  defp tray_accent(%{done: true}), do: "oklch(0.6 0.13 155)"
  defp tray_accent(%{hue: :neutral}), do: "oklch(0.7 0.02 255)"
  defp tray_accent(%{hue: hue}), do: "oklch(0.62 0.12 #{tray_hue(hue)})"

  defp tray_hue(:green), do: 155
  defp tray_hue(:amber), do: 65
  defp tray_hue(:violet), do: 292
  defp tray_hue(:blue), do: 250

  defp tray_style(open) do
    width = if open, do: "214px", else: "42px"

    "flex:0 0 auto;width:#{width};border-right:2px solid oklch(0.88 0.02 255);" <>
      "background:oklch(0.972 0.005 255);z-index:50;overflow:hidden;"
  end

  defp tray_count_style(padding) do
    "font-family:var(--font-mono);font-size:9px;font-weight:600;color:oklch(1 0 0);" <>
      "background:oklch(0.55 0.02 255);border-radius:20px;padding:#{padding};"
  end
end
