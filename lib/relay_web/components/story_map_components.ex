defmodule RelayWeb.StoryMapComponents do
  @moduledoc """
  The story map's rendering (RE264): pure function components over
  `RelayWeb.StoryMapGrid`'s view model, matching `docs/designs/Relay Story Map.dc.html`.

  Read-only and full zoom. The artboard's drag handles, inline `＋` add, `⠿` grips, `▾`
  collapse, `✦` suggest, `◎` focus, `✎` rename and the ZOOM/FILTER chrome are deliberately not
  rendered — RE260/RE261/RE262/RE263 own them, and the filter bar's owner chips, Needs-input
  toggle and `+ filter` own no card today.

  **Two derivations the artboard needs and our data does not carry**, each written exactly once
  here (`card_face/4`) and used for both the badge and the card's tint:

    * the badge label — `:needs_input` → `NEEDS YOU`, a stalled run → `STALLED`, otherwise the
      card's stage name upcased, with the sub-task percentage appended as `CODE · 62%`;
    * the hue — the artboard's `statusHue` mapped onto `Schemas.Stage.category`: done → green,
      needs-input or stalled → amber, `:in_progress` → violet (the mock's PLAN/CODE/DEPLOY),
      `:planning` → blue (SPEC/REVIEW), otherwise neutral.

  The percentage itself is `Relay.Cards.sub_task_pct/1` — the same number `board_card/1` draws.

  One deliberate copy change from the artboard: the tray's helper reads "No activity yet."
  Dragging does not exist until RE262, which restores the full sentence when the affordance is
  real.
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
  The CSS grid: sticky corner, the two backing header bands, lane striping, the sticky release
  rail, the activity band, the task headers, and one body cell per column × lane.
  """
  attr :grid, :any, required: true, doc: "a %RelayWeb.StoryMapGrid{}"
  attr :board, :any, required: true, doc: "the board, for Relay.Cards.ref/2"
  attr :stages, :list, required: true, doc: "board.stages, for the badge and Cards.done?/2"
  attr :stalled_ids, :any, required: true, doc: "MapSet of card ids whose run is stalled"

  def story_map(assigns) do
    ~H"""
    <div id="story-map-grid" style={grid_style(@grid)}>
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
        </div>
      </div>
      <div
        :for={{column, index} <- Enum.with_index(@grid.columns)}
        id={column_dom_id(column)}
        style={column_header_style(column, index)}
      >
        {column_name(column)}
      </div>
      <%= for {column, ci} <- Enum.with_index(@grid.columns), {lane, li} <- Enum.with_index(@grid.lanes) do %>
        <div
          id={StoryMapGrid.cell_dom_id(column.key, lane.key)}
          style={cell_style(column, ci, li)}
        >
          <.story_map_card
            :for={card <- Map.get(@grid.cells, {column.key, lane.key}, [])}
            {card_face(card, @board, @stages, @stalled_ids)}
          />
        </div>
      <% end %>
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
  """
  attr :cards, :list, required: true
  attr :board, :any, required: true
  attr :stages, :list, required: true
  attr :stalled_ids, :any, required: true
  attr :open, :boolean, default: true

  def unmapped_tray(assigns) do
    ~H"""
    <div id="story-map-tray" style={tray_style(@open)}>
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
          No activity yet.
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
  The day-one panel: RE263 (create structure) lands after this card, so on the day this merges
  every board has zero activities and this is the default experience, not an edge case. The
  tray renders alongside it, so the page is never blank and no card is missing.
  """
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
      <p style="font-size:11.5px;color:oklch(0.6 0.02 255);">
        Adding them is coming soon — until then every card sits in the UNMAPPED tray.
      </p>
    </div>
    """
  end

  # ---------- private renders ----------

  attr :face, :map, required: true

  defp tray_card(assigns) do
    ~H"""
    <div
      id={"story-map-tray-card-#{@face.ref}"}
      class="story-map-tray-card"
      role="button"
      tabindex="0"
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

  defp grid_style(grid) do
    columns = Enum.map_join(grid.columns, " ", fn _column -> "156px" end)
    rows = Enum.map_join(grid.lanes, " ", fn _lane -> "auto" end)

    "display:grid;grid-template-columns:128px #{columns};" <>
      "grid-template-rows:#{@h1}px #{@h2}px #{rows};align-items:start;min-width:max-content;"
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

    "grid-column:#{index + 2};grid-row:2;position:sticky;top:#{@h1}px;z-index:20;" <>
      "background:#{background};border-right:#{border_right};border-bottom:#{@gl_strong};" <>
      "padding:7px 9px;font-size:11.5px;font-weight:600;color:#{color};" <>
      "display:flex;align-items:center;gap:6px;"
  end

  defp cell_style(column, column_index, lane_index) do
    border_right =
      cond do
        column.no_task? -> @gl_dashed
        column.last_of_activity? -> @gl_strong
        true -> @gl_light
      end

    background = if column.no_task?, do: "background:#{@no_task_bg};", else: ""

    "grid-column:#{column_index + 2};grid-row:#{lane_index + 3};display:flex;" <>
      "flex-direction:column;gap:7px;padding:8px;min-height:26px;" <>
      "border-right:#{border_right};#{background}"
  end

  # The artboard's full-zoom `boxStyle` (cardVM, lines ~332-334), with `cursor:grab` swapped for
  # `cursor:pointer` — there is no drag until RE262.
  defp card_shell(_hue, true) do
    "background:oklch(0.97 0.015 150);border:1px solid oklch(0.88 0.04 150);border-radius:9px;" <>
      "padding:9px 10px;display:flex;flex-direction:column;gap:8px;" <>
      "box-shadow:0 1px 2.5px oklch(0.4 0.05 260/0.1);position:relative;overflow:hidden;" <>
      "cursor:pointer;opacity:0.8;border-left:3px solid oklch(0.6 0.13 155);"
  end

  defp card_shell(hue, _done) do
    {background, border} = tint(hue)

    "background:#{background};border:1px solid #{border};border-radius:9px;padding:9px 10px;" <>
      "display:flex;flex-direction:column;gap:8px;" <>
      "box-shadow:0 1px 2.5px oklch(0.4 0.05 260/0.1);position:relative;overflow:hidden;" <>
      "cursor:pointer;"
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
