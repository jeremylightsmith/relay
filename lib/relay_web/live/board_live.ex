defmodule RelayWeb.BoardLive do
  @moduledoc """
  The authenticated home (`/board`): the user's board rendered as stage
  columns grouped under category bands (Unstarted → In progress →
  Complete). Cards live in one LiveView stream per stage; each column's
  composer creates cards via `Relay.Cards` (MMF 03).

  MMF 04 adds the URL-driven card detail drawer ("?card=<ref>", handled
  in handle_params/3) rendered via RelayWeb.CoreComponents.card_drawer/1.

  MMF 05 makes cards movable: the BoardDnD drag-and-drop hook and the drawer's "Move to…"
  menu both push a "move_card" event; the server persists via Cards.move_card/3, resets the
  affected stage streams, and keeps the lane counts in sync.

  MMF 18 makes the board realtime: mount subscribes to `Relay.Events` for this
  board, and handle_info/2 applies the broadcast domain events (card_upserted,
  card_moved, timeline_appended, stages_changed) idempotently to the streams,
  counts, and open drawer — whether the change came from another browser
  session or from the REST API.

  RE264 adds the story map as a `:story_map` live_action at `/board/:slug/story-map` —
  the backbone × releases grid rendered by `RelayWeb.StoryMapComponents` over
  `RelayWeb.StoryMapGrid`'s pure view model. It is an action on THIS LiveView rather than
  its own, because clicking a card must open the full card drawer in place, and the drawer's
  ~50 assigns and ~40 event handlers live here. The grid itself is fully isolated in those
  two modules; this LiveView grows only by its mount assigns, one render branch, the
  action-derived patch targets (`board_path/1` / `card_path/2`) and `refresh_story_map/1`.

  RE263 adds the map's three create affordances. One assign, `:story_map_draft`
  (`nil | :activity | :release | {:task, activity_id}`), holds at most one open inline draft
  anywhere on the page, with `:story_map_draft_name` carrying its text; both are deliberately
  untouched by `refresh_story_map/1`, so a realtime refresh from another tab never eats what
  you are typing. Creates append via `Relay.StoryMap.next_position/1` and let the resulting
  `{:story_map_changed, board_id}` broadcast do the refetch — the creating tab included.

  RE260 adds the map's two view-only chrome controls: `:story_map_zoom` (`:map` | `:compact` |
  `:full`, defaulting to `:compact`) and `:story_map_hide_tasks`. Both are keys of the
  board-wide shared view alongside `:story_map_tray_open` (RE257) — **not** per-socket assigns:
  they change the grid's geometry, which is the coordinate space RE257's raw-pixel cursors are
  measured in, so viewers who disagree see each other's cursor over the wrong card.
  `:story_map_hide_tasks` is the sixth argument to `StoryMapGrid.build/7`; `:story_map_zoom`
  reaches only the renderer. Opening a `{:task, _}` draft turns Hide tasks off (through
  `merge_view/2`, which now also drops the activity from `collapsed` and clears a focus that is
  elsewhere), because a new task column has nowhere to render while the activity is merged.

  RE262 makes it writable: `"assign_card"` / `"unassign_card"` come from the `StoryMapDnD`
  hook rooted on `#story-map`, and both re-render through the `{:card_upserted, _}` echo rather
  than touching story-map assigns directly; `"compose_cell"` / `"cancel_compose_cell"` /
  `"create_card_in_cell"` drive the per-cell inline composer, whose open cell is
  `:story_map_compose` and whose form is the board's own `:compose_form`.

  RE261 makes the structure editable: `:story_map_edit` / `:story_map_edit_name` are the rename
  pair, mirroring the draft pair exactly (one open rename page-wide, untouched by
  `refresh_story_map/1`, mutually exclusive with the draft). `"story_map_delete"` refuses a
  structure that still holds cards — the ✕ is already `disabled` in that state, so the flash is
  defence in depth. Every new event joins the `read_only?` guard list.

  RE257 makes the map multi-user. `:presence_people` is `Relay.Presence`'s roster (empty
  anywhere but the map, re-derived on every `"presence_diff"`), rendered by
  `StoryMapComponents.presence_stack/1` in the `<:actions>` slot. `:story_map_tray_open`,
  `:story_map_zoom` and `:story_map_hide_tasks` are no longer private socket assigns: they are
  the board-wide shared view (`Relay.StoryMap.view/1` plus `merge_view/2`, the one writer that
  `put_view/3`, `toggle_view/2` and `toggle_view_member/4` all compose), so a
  toggle writes and re-renders from the write's own broadcast — the clicker included, one path,
  no optimistic local assign, and `assign_story_map_view/2` is the one place they are assigned.
  Every flip goes through `toggle_view/2` so it is computed on the committed row rather than the
  render-lagged assign. Tracking happens only for `live_action == :story_map`; untracking is the
  LiveView's exit.

  Cursors never touch assigns: `"cursor_moved"` is floored per socket (`@cursor_floor_ms`) and
  relayed on `Relay.Presence`'s cursor topic, and every receiver forwards it to its own client
  with `push_event/3`, which sends no template diff. The `StoryMapCursors` hook owns
  `#story-map-cursor-layer` (`phx-update="ignore"`), so the server holds no cursor state at all.

  RE259 adds the filter bar and the two view-narrowing controls. Four more keys of the same
  board-wide shared view — `:story_map_owner_filter`, `:story_map_needs_filter`,
  `:story_map_collapsed`, `:story_map_focus` — assigned in the same one place
  (`assign_story_map_view/2`) and written by the same six-event pattern: parse the wire value,
  write through `Relay.StoryMap`, re-render from that write's own broadcast. **Filtering is a
  pre-pass**: `story_map_viewport/1` narrows the card list with
  `RelayWeb.StoryMapFilter.visible/3` and builds the grid from the result, so no placement
  rule in `StoryMapGrid` knows filtering exists, `grid.total` is the visible count and
  `length(@story_map_cards)` is the total. Collapse and focus reach the grid as one MapSet via
  `StoryMapGrid.collapsed_set/3` — focus IS a collapse of everything else, and that rule lives
  in the grid, not here. Opening a task draft now expands its activity (dropping it from
  `collapsed` and clearing a focus that is elsewhere) in the same `merge_view/2` that turns
  Hide tasks off, because `＋ Add task` must never open an input the user cannot see.
  """

  use RelayWeb, :live_view

  alias Relay.Activity
  alias Relay.AgentLog
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Relay.Flows
  alias Relay.Members
  alias Relay.Presence
  alias Relay.Runs
  alias Relay.StoryMap
  alias Relay.Votes
  alias RelayWeb.ChangesetErrors
  alias RelayWeb.StoryMapComponents
  alias RelayWeb.StoryMapFilter
  alias RelayWeb.StoryMapGrid
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Run
  alias Schemas.Stage

  require Logger

  @category_order Stage.categories()

  # RLY-53 — the terminal Done column renders at most this many cards, with a
  # "Show N more" button revealing the next batch. Single definition in
  # Relay.Cards (RLY-227) so stage_neighbors/2's Done window matches this exactly.
  @done_page_size Cards.done_page_size()

  # RLY-112: nothing broadcasts when a card GOES QUIET — that is exactly what staleness
  # is. Without this clock a card never goes amber until something unrelated re-renders it.
  @health_tick_ms to_timeout(second: 30)

  # RLY-204: coalesce a burst of run events per socket into ONE scoped refetch. A board that
  # gets N run events for a card in this window does one flush, not N whole-board refetches.
  # Mirrors Relay.Runs.Scheduler.Server's Process.send_after + pending? debounce.
  @run_flush_debounce_ms 150

  # RE257 — the per-socket floor on relayed cursor frames. The StoryMapCursors hook already
  # throttles to <=20/s; this is the guard against a client that does not, so a hostile tab
  # cannot flood the board's cursor topic.
  @cursor_floor_ms 40

  # RLY-112: bounds ONE render (distinct from Pruner's storage retention). The artboard
  # rules a filter/expand toggle out of v1, so without this a card mid-run would try to
  # paint thousands of :action rows into the drawer. 200 covers the readable recent history.
  @activity_render_limit 200

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide crumb embed={@embed}>
      <:title>
        <span id="board-name" class="truncate max-w-[58vw] sm:max-w-[280px]">
          {@board.name}
        </span>
        <.board_view_tabs
          board_slug={@board.slug}
          active={if(@live_action == :story_map, do: :story_map, else: :board)}
        />
      </:title>
      <:actions>
        <StoryMapComponents.presence_stack
          :if={@live_action == :story_map}
          people={@presence_people}
          current_user_id={@current_scope.user.id}
        />
        <StoryMapComponents.story_map_toolbar
          :if={@live_action == :story_map}
          zoom={@story_map_zoom}
          hide_tasks={@story_map_hide_tasks}
        />
        <button
          :if={@stalled_count > 0 and not @read_only?}
          type="button"
          id="restart-stalled-button"
          phx-click="open_stalled"
          class="btn btn-warning btn-sm min-h-[44px]"
          aria-label={"Review #{@stalled_count} stalled cards"}
        >
          <.icon name="hero-arrow-path" class="size-4" />
          <span class="hidden sm:inline">Restart stalled</span>
          <span class="badge badge-sm badge-neutral">{@stalled_count}</span>
        </button>
        <button
          type="button"
          id="agent-logs-button"
          phx-click={if(@logs_open, do: "close_logs", else: "open_logs")}
          class={["btn btn-ghost btn-sm min-h-[44px] min-w-[44px]", @logs_open && "btn-active"]}
          aria-label="Agent log"
          aria-pressed={to_string(@logs_open)}
        >
          <.icon name="hero-command-line" class="size-5" />
        </button>
        <.link
          navigate={~p"/board/#{@board.slug}/settings"}
          id="board-settings-link"
          title="Board settings"
          aria-label="Board settings"
          class="flex min-h-[44px] min-w-[44px] items-center gap-[7px] rounded-lg px-3 text-[12px] font-semibold"
          style="background:oklch(1 0 0);border:1px solid oklch(0.90 0.006 255);color:oklch(0.40 0.02 255);"
        >
          <span style="width:13px;height:13px;border-radius:50%;border:2px solid oklch(0.55 0.02 255);position:relative;display:block;flex:0 0 auto;">
            <span style="position:absolute;top:2.5px;left:2.5px;width:4px;height:4px;border-radius:50%;background:oklch(0.55 0.02 255);">
            </span>
          </span>
          <span class="hidden sm:inline">Board settings</span>
        </.link>
      </:actions>
      <:menu_items>
        <li>
          <button type="button" id="archived-cards-menu-item" phx-click="open_archived">
            <.icon name="hero-archive-box" class="size-4" />
            <span class="flex-1">Archived cards</span>
            <span class="font-mono text-xs text-base-content/60">{@archived_count}</span>
          </button>
        </li>
      </:menu_items>
      <div
        :if={@live_action not in [:card, :story_map]}
        id="board-viewport"
        class={[
          "flex min-h-0 flex-col",
          if(@embed, do: "h-dvh", else: "h-[calc(100dvh_-_53px)]")
        ]}
      >
        <div id="board" phx-hook="BoardDnD" class="flex min-h-0 flex-1 flex-col">
          <div
            :if={@read_only?}
            id="read-only-banner"
            class="mx-4 mb-2 mt-2 flex items-center gap-3 rounded-lg px-4 py-2.5 text-sm sm:mx-5"
            style="background:oklch(0.97 0.04 85);border:1px solid oklch(0.85 0.09 85);color:oklch(0.42 0.09 85);"
          >
            <.icon name="hero-archive-box" class="size-4" />
            <span class="flex-1">This board is archived and read-only.</span>
            <button
              type="button"
              id="restore-board-button"
              phx-click="restore_board"
              class="btn btn-sm"
            >
              Restore
            </button>
          </div>
          <div
            :if={@stopped_work}
            id="stopped-work-banner"
            class="mx-4 mb-2 mt-2 flex items-center gap-3 rounded-lg px-4 py-2.5 text-sm sm:mx-5"
            style={stopped_work_banner_style(@stopped_work.reason)}
          >
            <.icon name="hero-exclamation-triangle" class="size-4" />
            <span class="flex-1">{@stopped_work.detail}</span>
          </div>
          <%!-- RLY-94 · BOARD-01 — phone-width pager nav: compact header + stage chip
                strip. Hidden at ≥45rem; the BoardPager hook owns the data-active
                highlight and chip-tap scrolling (see assets/js/hooks/board_pager.js). --%>
          <nav
            id="board-pager-nav"
            phx-hook="BoardPager"
            class="board-pager-nav drawer:hidden"
            aria-label="Stages"
          >
            <%!-- RLY-95 · BOARD-01 — `‹ back · board name`: the ‹ is the route back to
                  /boards once embed hides the web top bar. ?from= drives the CURRENT
                  badge on the list. The updated artboard drops the card count. --%>
            <div id="board-pager-header" class="board-pager-header">
              <.link
                id="board-pager-back"
                navigate={~p"/boards?from=#{@board.slug}"}
                class="board-pager-back"
                aria-label="All boards"
              >
                ‹
              </.link>
              <span class="board-pager-title">{@board.name}</span>
              <%!-- RLY-126 · BOARD-04 — embed-only: opens the NATIVE New-card sheet via the
                    BoardPager hook's relayCreateCard bridge. Plain web has no native handler,
                    so the button does not render outside embed mode. --%>
              <button
                :if={@embed}
                type="button"
                id="board-create-card"
                class="board-pager-create"
                aria-label="New card"
                data-board={@board.slug}
                data-stages={Jason.encode!(for stage <- flat_stages(@stage_groups), do: stage.name)}
              >
                +
              </button>
            </div>
            <div class="board-pager-chips">
              <button
                :for={stage <- flat_stages(@stage_groups)}
                type="button"
                id={"stage-chip-#{stage.id}"}
                class="board-pager-chip"
                data-chip-stage-id={stage.id}
                data-stage-name={stage.name}
                data-ai={to_string(stage.ai_enabled)}
              >
                <span class="board-pager-chip-dot"></span>
                {stage.name}
                <span class="board-pager-chip-count">
                  {total_count(stage, @stage_counts, @sublanes_by_parent)}
                </span>
              </button>
            </div>
            <span class="board-pager-fade" aria-hidden="true"></span>
          </nav>
          <div
            id="board-bands"
            class="drawer:min-w-0 drawer:w-auto drawer:overflow-x-auto drawer:overflow-y-hidden drawer:[-webkit-overflow-scrolling:touch] drawer:[overscroll-behavior-x:contain]"
            style="display:flex;gap:22px;padding:16px 18px 18px 18px;align-items:stretch;background:oklch(0.952 0.008 255);flex:1 1 auto;min-height:0;"
          >
            <section
              :for={{category, stages} <- @stage_groups}
              id={"category-#{category}"}
              style="display:flex;flex-direction:column;gap:9px;flex:0 0 auto;"
            >
              <div
                class="category-band-header"
                style="display:flex;align-items:center;gap:8px;padding:0 4px;height:20px;flex:0 0 auto;"
              >
                <span class="category-dot" style={category_dot_style(category)}></span>
                <h2
                  class="category-band"
                  style="font-size:10.5px;font-weight:600;letter-spacing:0.09em;text-transform:uppercase;font-family:var(--font-mono);color:oklch(0.52 0.02 255);margin:0;"
                >
                  {category_label(category)}
                </h2>
                <span style="font-size:10.5px;font-family:var(--font-mono);color:oklch(0.68 0.02 255);">
                  {category_card_count(category, stages, @stage_counts, @sublanes_by_parent)}
                </span>
              </div>
              <div
                class="category-stages"
                style="display:flex;gap:9px;align-items:stretch;flex:1;min-height:0;"
              >
                <.stage_column
                  :for={stage <- stages}
                  id={"stage-col-#{stage.position}"}
                  name={stage.name}
                  type={stage.type}
                  ai_enabled={stage.ai_enabled}
                  category={category}
                  stage_id={stage.id}
                  collapsed={
                    not @pager_mode and
                      stage_collapsed?(
                        stage,
                        @stage_counts,
                        @sublanes_by_parent,
                        @force_open,
                        @stage_force_closed
                      )
                  }
                  main_collapsed={
                    lane_collapsed?(stage.id, :main, @stage_counts, @force_open, @force_closed)
                  }
                  count={Map.fetch!(@stage_counts, stage.id)}
                  wip_limit={stage.wip_limit}
                  board_key={@board.key}
                  terminal={stage.id == @terminal_stage_id}
                  revealed={if(stage.id == @terminal_stage_id, do: @done_revealed)}
                  questions={@needs_input_questions}
                  health={@health_by_card}
                  runs={@face_runs}
                  run_meta={@run_face_meta}
                  vote_counts={@vote_counts}
                  cards={Map.fetch!(@streams, stream_name(stage.id))}
                  composing={@composing_stage_id == stage.id}
                  compose_form={@compose_form}
                  composable={not @embed}
                  read_only={@read_only?}
                  sublanes={
                    for sub <- Map.get(@sublanes_by_parent, stage.id, []) do
                      %{
                        id: sub.id,
                        name: lane_label(sub.type),
                        lane: sub.type,
                        owner: :human,
                        count: Map.fetch!(@stage_counts, sub.id),
                        cards: Map.fetch!(@streams, stream_name(sub.id)),
                        collapsed:
                          lane_collapsed?(sub.id, sub.type, @stage_counts, @force_open, @force_closed)
                      }
                    end
                  }
                />
              </div>
            </section>
          </div>
        </div>
        <div
          :if={@logs_open}
          id="agent-log-sheet"
          class="flex-none border-t border-base-300 bg-base-100"
          role="log"
          aria-label="Agent log"
        >
          <div class="flex items-center justify-between border-b border-base-200 px-4 py-1.5">
            <div class="flex items-center gap-2 font-mono text-xs uppercase tracking-wider text-base-content/60">
              <.icon name="hero-command-line" class="size-4" /> Agent log
            </div>
            <button
              type="button"
              id="agent-log-close"
              phx-click="close_logs"
              class="btn btn-ghost btn-xs btn-circle"
              aria-label="Close agent log"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <div
            id="agent-log-lines"
            phx-update="stream"
            class="h-48 overflow-y-auto px-4 py-2 font-mono text-xs leading-relaxed"
          >
            <div
              id="agent-log-empty"
              class="hidden py-6 text-center text-base-content/50 only:block"
            >
              Waiting for agent activity…
            </div>
            <div
              :for={{dom_id, entry} <- @streams.agent_logs}
              id={dom_id}
              class={["flex gap-2 py-0.5", agent_log_class(entry.kind)]}
            >
              <span class="shrink-0 text-base-content/40">
                {Calendar.strftime(entry.ts, "%H:%M:%S")}
              </span>
              <span :if={entry.ref} class="shrink-0 text-base-content/60">[{entry.ref}]</span>
              <span class="whitespace-pre-wrap break-all">{entry.text}</span>
            </div>
          </div>
        </div>
      </div>
      <.story_map_viewport
        :if={@live_action == :story_map}
        board={@board}
        activities={@story_activities}
        tasks={@story_tasks}
        releases={@releases}
        cards={@story_map_cards}
        stalled_cards={@stalled_cards}
        tray_open={@story_map_tray_open}
        draft={@story_map_draft}
        draft_name={@story_map_draft_name}
        edit={@story_map_edit}
        edit_name={@story_map_edit_name}
        read_only={@read_only?}
        compose={@story_map_compose}
        compose_form={@compose_form}
        embed={@embed}
        zoom={@story_map_zoom}
        hide_tasks={@story_map_hide_tasks}
        owner_filter={@story_map_owner_filter}
        needs_input_filter={@story_map_needs_filter}
        collapsed={@story_map_collapsed}
        focus={@story_map_focus}
      />
      <.card_drawer
        :if={@selected_card}
        id="card-drawer"
        board_slug={@board.slug}
        embed={@embed}
        card_nav_enabled={not @embed and @live_action not in [:card, :story_map]}
        prev_ref={@prev_ref}
        next_ref={@next_ref}
        ref={Cards.ref(@board, @selected_card)}
        card={@selected_card}
        stage_name={drawer_stage_name(@selected_stage, @board.stages)}
        stage_owner={stage_owner(@selected_stage)}
        stages={move_targets(@board, @selected_card)}
        active_owner={Cards.active_owner_type(@selected_card)}
        health={health_state(@health_by_card, @selected_card.id)}
        done={Cards.done?(@selected_card, @board.stages)}
        close_patch={board_path(assigns)}
        title_form={@title_form}
        editing_title={@editing_title}
        editing_tag={@editing_tag}
        tag_form={@tag_form}
        tag_suggestions={@tag_suggestions}
        editing_description={@editing_description}
        description_form={@description_form}
        editing_acceptance_criteria={@editing_acceptance_criteria}
        expanded_acceptance_criteria={@expanded_acceptance_criteria?}
        acceptance_criteria_form={@acceptance_criteria_form}
        editing_spec={@editing_spec}
        editing_plan={@editing_plan}
        expanded_spec={@expanded_spec?}
        expanded_plan={@expanded_plan?}
        spec_form={@spec_form}
        plan_form={@plan_form}
        current_user_id={@current_scope.user.id}
        members={@members}
        reassign_open={@reassign_open}
        conversation={@streams.conversation}
        note_count={MapSet.size(@note_ids)}
        activity={@streams.activity}
        comment_form={@comment_form}
        question={@question}
        answer_form={@answer_form}
        answer_questions={@answer_questions}
        answer_step={@answer_step}
        answer_values={@answer_values}
        review_gate={@review_gate}
        reject_open={@reject_open}
        reject_form={@reject_form}
        reject_error={@reject_error}
        archived={Card.archived?(@selected_card)}
        body_loading={@body_loading?}
        drawer_tab={@drawer_tab}
        runs={@card_runs}
        run_flow={@card_runs != [] && Enum.find(@flows, &(&1.key == hd(@card_runs).flow_key))}
        queued_flow={
          Runs.queued_flow(
            @selected_card,
            Cards.active_owner_type(@selected_card),
            @flows,
            Map.get(@run_summaries, @selected_card.id)
          )
        }
        vote_count={@drawer_vote_count}
        supporters={@drawer_supporters}
        public_description={@selected_card.public_description}
        editing_public_desc={@editing_public_desc}
        public_desc_form={@public_desc_form}
      />
      <div
        :if={@archived_open}
        id="archived-modal"
        class="modal modal-open"
        role="dialog"
        aria-label="Archived cards"
      >
        <div class="modal-box max-w-2xl">
          <div class="flex items-center justify-between">
            <h3 class="text-lg font-semibold">Archived cards</h3>
            <button
              type="button"
              id="archived-modal-close"
              phx-click="close_archived"
              class="btn btn-sm btn-circle btn-ghost"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <ul id="archived-list" class="mt-4 divide-y divide-base-200">
            <li
              :for={card <- @archived_cards}
              id={"archived-row-#{card.id}"}
              class="flex items-center gap-3 py-2.5"
            >
              <button
                type="button"
                id={"open-archived-card-#{card.id}"}
                phx-click="open_archived_card"
                phx-value-ref={Cards.ref(@board, card)}
                class="min-w-0 flex-1 text-left"
              >
                <div class="flex items-baseline gap-2">
                  <span class="font-mono text-xs text-base-content/60">
                    {Cards.ref(@board, card)}
                  </span>
                  <span class="truncate font-medium">{card.title}</span>
                </div>
                <div class="text-xs text-base-content/50">
                  {drawer_stage_name(card.stage, @board.stages)} · archived {Calendar.strftime(
                    card.archived_at,
                    "%b %d, %Y"
                  )}
                </div>
              </button>
              <button
                type="button"
                id={"archived-restore-#{card.id}"}
                phx-click="restore_card"
                phx-value-ref={Cards.ref(@board, card)}
                class="btn btn-sm"
              >
                Restore
              </button>
            </li>
            <li :if={@archived_cards == []} class="py-3 text-sm text-base-content/50">
              No archived cards.
            </li>
          </ul>
        </div>
        <label class="modal-backdrop" phx-click="close_archived">Close</label>
      </div>
      <div
        :if={@stalled_open}
        id="stalled-modal"
        class="modal modal-open"
        role="dialog"
        aria-label="Stalled cards"
      >
        <div class="modal-box max-w-2xl">
          <div class="flex items-center justify-between">
            <h3 class="text-lg font-semibold">Stalled cards</h3>
            <button
              type="button"
              id="stalled-modal-close"
              phx-click="close_stalled"
              class="btn btn-sm btn-circle btn-ghost"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <div :if={@stalled_error} id="stalled-error" class="alert alert-error mt-4 text-sm">
            {@stalled_error}
          </div>
          <ul id="stalled-list" class="mt-4 divide-y divide-base-200">
            <li
              :for={%{card: card, reason: reason} <- @stalled_cards}
              id={"stalled-row-#{card.id}"}
              class="flex items-center gap-3 py-2.5"
            >
              <button
                type="button"
                id={"open-stalled-card-#{card.id}"}
                phx-click="open_stalled_card"
                phx-value-ref={Cards.ref(@board, card)}
                class="min-w-0 flex-1 text-left"
              >
                <div class="flex items-baseline gap-2">
                  <span class="font-mono text-xs text-base-content/60">
                    {Cards.ref(@board, card)}
                  </span>
                  <span class="truncate font-medium">{card.title}</span>
                </div>
                <div class="text-xs text-base-content/50">
                  {drawer_stage_name(card.stage, @board.stages)} · {reason}
                </div>
              </button>
              <button
                type="button"
                id={"stalled-restart-#{card.id}"}
                phx-click="restart_one"
                phx-value-ref={Cards.ref(@board, card)}
                class="btn btn-sm btn-warning"
              >
                Restart
              </button>
            </li>
            <li :if={@stalled_cards == []} class="py-3 text-sm text-base-content/50">
              No stalled cards.
            </li>
          </ul>
        </div>
        <label class="modal-backdrop" phx-click="close_stalled">Close</label>
      </div>
      <div
        :if={@pending_move}
        id="stranded-move-modal"
        class="modal modal-open"
        role="dialog"
        aria-label="Confirm move"
      >
        <div class="modal-box max-w-md">
          <h3 class="text-lg font-semibold">Cancel this run and move the card?</h3>
          <p class="mt-3 text-sm text-base-content/80">
            <span class="font-medium">{@pending_move.ref}</span>
            has a {@pending_move.status} run
            (<span class="font-medium">{@pending_move.node}</span>, {@pending_move.flow_key} flow).
            Moving it to <span class="font-medium">{@pending_move.target_stage_name}</span>
            will cancel that run and free its executor slot.
          </p>
          <div class="modal-action">
            <button
              type="button"
              id="stranded-move-cancel"
              phx-click="cancel_move"
              class="btn btn-ghost"
            >
              Keep it here
            </button>
            <button
              type="button"
              id="stranded-move-confirm"
              phx-click="confirm_move"
              class="btn btn-error"
            >
              Cancel run &amp; move
            </button>
          </div>
        </div>
        <label class="modal-backdrop" phx-click="cancel_move">Close</label>
      </div>
    </Layouts.app>
    """
  end

  # RE264 — the story-map viewport: the tray on the left, the scrolling map body on the right
  # (artboard line ~78). The grid is built HERE, once, so both the tray and the grid read the
  # same view model without a second `StoryMapGrid.build/7`.
  attr :board, :any, required: true
  attr :activities, :list, required: true
  attr :tasks, :list, required: true
  attr :releases, :list, required: true
  attr :cards, :list, required: true
  attr :stalled_cards, :list, required: true
  attr :tray_open, :boolean, required: true
  attr :draft, :any, required: true
  attr :draft_name, :string, required: true
  attr :edit, :any, required: true
  attr :edit_name, :string, required: true
  attr :read_only, :boolean, required: true
  attr :compose, :any, required: true
  attr :compose_form, :any, required: true
  attr :embed, :boolean, required: true
  attr :zoom, :atom, required: true
  attr :hide_tasks, :boolean, required: true
  attr :owner_filter, :list, required: true
  attr :needs_input_filter, :boolean, required: true
  attr :collapsed, :list, required: true
  attr :focus, :any, required: true, doc: "the focused activity id, or nil"

  defp story_map_viewport(assigns) do
    # RE259 — filtering is a PRE-PASS, not a grid concern: the grid is built from the
    # VISIBLE cards, so its placement rules are untouched, `grid.total` is the visible
    # count and `length(@cards)` is the total — the two numbers the count label needs.
    # Every count the map already shows (band badges, lane `N cards`, the ✕ block) then
    # narrows with the filter for free, exactly as the artboard does.
    #
    # Consequence worth stating: the ✕ delete button un-blocks when a filter hides an
    # activity's last card. The SERVER still refuses a non-empty delete with
    # `{:error, :not_empty}` (the existing defence in depth), so the outcome is a refused
    # click, not lost cards. Accepted; the alternative is a second set of unfiltered
    # counts threaded through the grid for one edge case.
    visible = StoryMapFilter.visible(assigns.cards, assigns.owner_filter, assigns.needs_input_filter)

    assigns =
      assigns
      |> assign(
        :grid,
        StoryMapGrid.build(
          assigns.activities,
          assigns.tasks,
          assigns.releases,
          visible,
          assigns.draft,
          assigns.hide_tasks,
          StoryMapGrid.collapsed_set(assigns.activities, assigns.collapsed, assigns.focus)
        )
      )
      # Chips come from the UNFILTERED list plus the selection, so selecting an owner
      # never removes the other chips.
      |> assign(:chips, StoryMapFilter.chips(assigns.cards, assigns.owner_filter))
      |> assign(:filter_active, StoryMapFilter.active?(assigns.owner_filter, assigns.needs_input_filter))
      |> assign(:focus_activity, StoryMapGrid.resolve_focus(assigns.activities, assigns.focus))
      |> assign(:stalled_ids, MapSet.new(assigns.stalled_cards, & &1.card.id))

    ~H"""
    <%!-- RE259 — the filter bar and the map share ONE height-owning flex column, so the
          two `h-[calc(100dvh_-_53px)]` magic numbers stay at one and `#story-map` becomes
          `flex-1 min-h-0` instead of the arithmetic doubling. --%>
    <div
      id="story-map-viewport"
      class={["flex min-h-0 flex-col", if(@embed, do: "h-dvh", else: "h-[calc(100dvh_-_53px)]")]}
    >
      <StoryMapComponents.story_map_filter_bar
        chips={@chips}
        needs_input={@needs_input_filter}
        focus_name={@focus_activity && @focus_activity.name}
        filter_active={@filter_active}
        visible={@grid.total}
        total={length(@cards)}
      />
      <div
        id="story-map"
        phx-hook="StoryMapDnD"
        class="flex min-h-0 flex-1"
        style="background:oklch(0.95 0.006 255);"
      >
        <%!--
        RE262 — the tray renders unconditionally, unlike the artboard's `trayShown:
        unmappedAll.length>0`. It is the only drop target that unmaps a card, so hiding it when
        the list empties makes unmapping unreachable exactly when every card is placed — the
        steady state this feature drives a board toward.
        --%>
        <StoryMapComponents.unmapped_tray
          cards={@grid.unmapped}
          board={@board}
          stages={@board.stages}
          stalled_ids={@stalled_ids}
          open={@tray_open}
        />
        <div id="story-map-surface" class="relative min-w-0 flex-1 overflow-auto">
          <%!--
          RE257 — the cursor overlay. Absolutely positioned at the scroll container's
          CONTENT origin (which is #story-map-grid's origin) and 0x0, so its children are
          placed in the same raw-pixel content space the hook measures, scroll with the
          map, and are never clipped. phx-update="ignore" because the hook owns every node
          inside it; the server holds no cursor state.
          --%>
          <div
            id="story-map-cursor-layer"
            phx-hook="StoryMapCursors"
            phx-update="ignore"
            style="position:absolute;top:0;left:0;width:0;height:0;z-index:40;pointer-events:none;"
          >
          </div>
          <%!-- RE259 — the branch is on ACTIVITIES, not `grid.bands`: a board whose every
                activity is collapsed has no bands but is not empty, and would otherwise
                render the day-one panel on top of its own stubs. --%>
          <StoryMapComponents.story_map
            :if={@activities != []}
            grid={@grid}
            board={@board}
            stages={@board.stages}
            stalled_ids={@stalled_ids}
            draft={@draft}
            draft_name={@draft_name}
            edit={@edit}
            edit_name={@edit_name}
            read_only={@read_only}
            compose={@compose}
            compose_form={@compose_form}
            zoom={@zoom}
            focus={@focus_activity}
          />
          <StoryMapComponents.story_map_empty
            :if={@activities == []}
            draft={@draft}
            draft_name={@draft_name}
            read_only={@read_only}
          />
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket), do: mount_board(socket, slug)

  # RLY-87 — /cards/:ref, the native card host. Resolves the ref across the user's boards
  # (Cards.resolve_ref/3, the same rule the /api/all surface uses), then runs the *same*
  # board setup as the slug clause, so every assign card_drawer/1 expects is present and
  # identical to the board path.
  #
  # resolve_ref/3 returns a board from list_boards/1 — no stages preloaded — so we reload by
  # slug through Boards.get_board!/2, which is exactly what mount_board/2 already does.
  #
  # Card mode implies embed: this route exists to be hosted in the app's webview, so it is
  # chromeless by construction rather than by the caller passing ?embed=1. The on_mount
  # :mount_embed hook assign_new's :embed from the session before mount/3 runs; assigning
  # here overrides it.
  @impl true
  def mount(%{"ref" => ref} = params, _session, socket) do
    case Cards.resolve_ref(socket.assigns.current_scope.user, ref, params["board"]) do
      {:ok, board, _card} ->
        socket |> assign(:embed, true) |> mount_board(board.slug)

      # Unknown ref, a board the user cannot see, or an ambiguous duplicate-key ref: all 404.
      # Never leak the difference, and never guess a card.
      {:error, _reason} ->
        raise Ecto.NoResultsError, queryable: Card
    end
  end

  defp mount_board(socket, slug) do
    board = Boards.get_board!(socket.assigns.current_scope.user, slug)

    live? = connected?(socket)
    story_map? = socket.assigns.live_action == :story_map

    if live? do
      Events.subscribe(board.id)
      Runs.subscribe(board.id)
      :timer.send_interval(@health_tick_ms, self(), :health_tick)
    end

    # RE257 — presence is scoped to the STORY MAP (interview decision 3): only people viewing
    # the map appear in the stack, so the kanban board neither tracks nor subscribes. There is
    # no untrack call anywhere: Phoenix.Presence untracks on the tracked pid's exit, and the
    # Board ↔ Story map switch is a `<.link navigate>`, which shuts this LiveView down.
    if live? and story_map?, do: join_story_map_presence(board, socket.assigns.current_scope.user)

    presence_people = if live? and story_map?, do: Presence.list_people(board.id), else: []

    cards = Cards.list_cards(board)
    flows = Flows.list_flows(board)
    run_summaries = Runs.run_summaries_for_board(board)
    cards_by_stage = Enum.group_by(cards, & &1.stage_id)

    socket =
      socket
      |> assign(:page_title, board.name)
      |> assign(:board, board)
      # RE264 — the story map's inputs, loaded unconditionally: three small board-scoped indexed
      # selects, negligible next to the ~10 queries already here, and unconditional means there
      # is no stale-assign branch to get wrong. `story_map_cards` is the SAME list this mount
      # already loaded — no extra query.
      |> assign(:story_activities, StoryMap.list_activities(board))
      |> assign(:story_tasks, StoryMap.list_tasks(board))
      |> assign(:releases, StoryMap.list_releases(board))
      |> assign(:story_map_cards, cards)
      # RE257 — the map's view settings are SHARED, board-wide, not per-socket assigns: every
      # viewer of a board must be looking at the same map, which is what makes a raw-pixel
      # cursor land on the right card. Seeded from the persisted view so a late joiner opens on
      # what everyone else is already on, and re-assigned only from the write's own
      # {:story_map_view_changed, _, _} broadcast.
      |> assign_story_map_view(StoryMap.view(board))
      # RE257 — the story-map roster, [] anywhere but the map. Re-derived from Relay.Presence on
      # every diff, never patched from the diff payload: one person with three tabs is three
      # joins and one avatar, and only list_people/1 knows that.
      |> assign(:presence_people, presence_people)
      # RE257 — the per-socket floor on relayed cursor frames. Seeded a full floor in the past
      # so the first move of a session always relays.
      |> assign(:cursor_last_ms, System.monotonic_time(:millisecond) - @cursor_floor_ms)
      # RE263 — the ONE open inline draft: nil | :activity | :release | {:task, activity_id}.
      # Deliberately untouched by refresh_story_map/1, so another tab creating an activity never
      # eats what you are typing. `story_map_draft_name` tracks the text server-side for the
      # same reason `compose_form` does (see validate_card): LiveView only patches an input whose
      # server-rendered value changed.
      |> assign(:story_map_draft, nil)
      |> assign(:story_map_draft_name, "")
      # RE261 — the ONE open inline rename: nil | {:activity, id} | {:task, id} | {:release,
      # id}, at most one anywhere on the page. Untouched by refresh_story_map/1 for exactly the
      # reason the draft pair is: another tab's edit must never eat what you are typing.
      |> assign(:story_map_edit, nil)
      |> assign(:story_map_edit_name, "")
      # RE262 — the {column_key, lane_key} whose inline composer is open, or nil. The form
      # itself is the board's existing :compose_form: one composer is open at a time anywhere
      # on this socket, so one form assign is the whole state.
      |> assign(:story_map_compose, nil)
      |> assign_stalled()
      |> assign(:stalled_open, false)
      |> assign(:stalled_error, nil)
      |> assign(:read_only?, Board.archived?(board))
      |> assign(:archived_count, Cards.count_archived_cards(board))
      |> assign(:archived_open, false)
      |> assign(:archived_cards, [])
      |> assign(:pending_move, nil)
      |> assign(:logs_open, false)
      |> assign(:agent_log_ids, [])
      |> stream_configure(:agent_logs, dom_id: &"agent-log-#{&1.id}")
      |> assign(:stage_groups, group_stages(board.stages))
      |> assign(:stage_counts, stage_counts(board.stages, cards_by_stage))
      |> assign(:sublanes_by_parent, sublanes_by_parent(board.stages))
      |> assign(:pager_mode, false)
      |> assign_board_derivations(board)
      |> assign(:health_by_card, health_by_card(cards, board.stages))
      |> assign(:done_revealed, @done_page_size)
      |> assign(:force_open, MapSet.new())
      |> assign(:force_closed, MapSet.new())
      |> assign(:stage_force_closed, MapSet.new())
      |> assign(:composing_stage_id, nil)
      |> assign(:compose_form, empty_compose_form())
      |> assign(:members, Members.list_members(board))
      |> assign(:reassign_open, false)
      |> assign(:body_loading?, false)
      |> assign(:flows, flows)
      |> assign(:run_summaries, run_summaries)
      |> assign(:face_runs, face_runs(cards, flows, run_summaries))
      |> assign(:vote_counts, Votes.counts_for_cards(Enum.map(cards, & &1.id)))
      |> assign(:drawer_supporters, [])
      |> assign(:drawer_vote_count, 0)
      |> assign(:editing_public_desc, false)
      |> assign(:public_desc_form, nil)
      |> assign(:dirty_run_cards, MapSet.new())
      |> assign(:run_flush_events, 0)
      |> assign(:run_flush_pending?, false)
      |> assign_run_diagnostics(board, run_summaries)
      |> assign(:note_ids, MapSet.new())
      |> stream_configure(:conversation, dom_id: &conversation_dom_id/1)
      |> stream_configure(:activity, dom_id: &activity_dom_id/1)

    socket =
      Enum.reduce(board.stages, socket, fn stage, acc ->
        stream_stage(acc, stage.id, cards_by_stage)
      end)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_selected_card(socket, card_ref(socket.assigns.live_action, params))}
  end

  # Card mode selects from the path (/cards/:ref); board mode from ?card=<ref>. In card mode
  # the selection is never nil'd — there is no board behind the drawer to close back to.
  defp card_ref(:card, params), do: params["ref"]
  defp card_ref(_action, params), do: params["card"]

  # RLY-68 — the async heavy-body fetch kicked off by
  # maybe_start_body_load/4. Compares the result's card id against the
  # live selected_card so a fill that resolves after the user has since
  # switched cards (or closed the drawer) is dropped instead of
  # overwriting the wrong content.
  @impl true
  def handle_async(:load_card_body, {:ok, result}, socket) do
    %{card_id: card_id, card: card, activity: activity, conversation: conversation} = result

    case socket.assigns.selected_card do
      %Card{id: ^card_id} ->
        runs = Runs.list_runs_for_card(card)
        latest = List.first(runs)
        default_tab = if latest && latest.status in Run.active_statuses(), do: :run, else: :detail
        {supporters, vote_count} = Votes.supporters(card, 5)

        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:body_loading?, false)
         |> assign(:question, latest_question(card, activity))
         |> assign(:answer_questions, latest_questions(card, activity))
         |> assign(:answer_step, 0)
         |> assign(:answer_values, %{})
         |> assign_review(card)
         |> assign(:card_runs, runs)
         |> assign(:drawer_tab, default_tab)
         |> assign(:drawer_supporters, supporters)
         |> assign(:drawer_vote_count, vote_count)
         |> stream_notes(conversation)
         |> stream(:activity, activity, reset: true)}

      _stale ->
        {:noreply, socket}
    end
  end

  def handle_async(:load_card_body, {:exit, reason}, socket) do
    Logger.warning("optimistic drawer body load failed: #{inspect(reason)}")
    {:noreply, assign(socket, :body_loading?, false)}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{read_only?: true}} = socket) when event in ~w(
        compose create_card move_card assign_card unassign_card compose_cell create_card_in_cell
        save_card_title save_card_tag
        save_card_description
        save_card_acceptance_criteria save_card_spec save_card_plan
        add_owner remove_owner take_over post_comment answer_input
        answer_select answer_custom answer_next answer_back answer_goto answer_submit
        review_approve review_reject retry_card retry_run confirm_move cancel_move
        archive_card restore_card toggle_sub_task restart_one
        story_map_add_activity story_map_add_task story_map_add_release story_map_draft_submit
        story_map_rename_start story_map_rename_change story_map_rename_submit
        story_map_rename_cancel story_map_delete story_map_reorder
      ) do
    {:noreply, put_flash(socket, :error, "This board is archived (read-only).")}
  end

  def handle_event("restore_board", _params, socket) do
    {:ok, _board} = Boards.unarchive_board(socket.assigns.board)
    {:noreply, reload_board(socket)}
  end

  def handle_event("compose", %{"stage-id" => stage_id}, socket) do
    {:noreply,
     socket
     |> assign(:composing_stage_id, String.to_integer(stage_id))
     |> assign(:compose_form, empty_compose_form())}
  end

  def handle_event("cancel_compose", _params, socket) do
    {:noreply, assign(socket, :composing_stage_id, nil)}
  end

  # RLY-53 — reveal the next batch of the terminal Done column: grow
  # done_revealed by a page and re-derive the terminal stream to the newest
  # done_revealed cards (reset keeps only the bounded window in the DOM).
  def handle_event("show_more_done", %{"stage-id" => stage_id}, socket) do
    stage_id = String.to_integer(stage_id)

    if stage_id == socket.assigns.terminal_stage_id do
      socket = update(socket, :done_revealed, &(&1 + @done_page_size))
      {:noreply, stream_stage(socket, stage_id, %{}, reset: true)}
    else
      {:noreply, socket}
    end
  end

  # Tracks the composer's live value server-side (LiveView only patches the
  # client DOM when a tracked assign's rendered value actually changes). Without
  # this, the server's view of the input is always "" before and after create,
  # so resetting to empty_compose_form/0 in create_card is a no-op diff and the
  # just-submitted text is left showing in the browser.
  def handle_event("validate_card", %{"card" => card_params}, socket) do
    {:noreply, assign(socket, :compose_form, to_form(card_params, as: :card))}
  end

  def handle_event("create_card", %{"stage_id" => stage_id, "card" => card_params}, socket) do
    stage = find_stage(socket, stage_id)

    case stage && Cards.create_card(stage, card_params, current_actor(socket)) do
      nil ->
        {:noreply, socket}

      {:ok, card} ->
        {:noreply,
         socket
         |> stream_insert(stream_name(stage.id), card, at: 0)
         |> update(:stage_counts, &Map.update!(&1, stage.id, fn count -> count + 1 end))
         |> assign(:compose_form, empty_compose_form())
         |> push_event("focus_card", %{ref: Cards.ref(socket.assigns.board, card)})}

      {:error, changeset} ->
        {:noreply, assign(socket, :compose_form, to_form(changeset))}
    end
  end

  # RLY-94 — in embed mode a card tap escapes the webview: the shell pushes the
  # native CardScreen (BOARD-03) instead of the in-webview drawer opening. On web
  # (non-embed) the drawer keeps working at every width.
  def handle_event("select_card", %{"ref" => ref}, %{assigns: %{embed: true}} = socket) do
    {:noreply, push_card_tap(socket, ref)}
  end

  def handle_event("select_card", %{"ref" => ref}, socket) do
    {:noreply, push_patch(socket, to: card_path(socket.assigns, ref))}
  end

  # Card mode (/cards/:ref) has no board behind the drawer to close back to — the native
  # back chevron owns dismissal (RLY-87).
  def handle_event("close_drawer", _params, %{assigns: %{live_action: :card}} = socket) do
    {:noreply, socket}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, push_patch(socket, to: board_path(socket.assigns))}
  end

  # RLY-227 — step to the prev/next card in the open card's stage column. The refs
  # come from @prev_ref/@next_ref (Cards.stage_neighbors/2); a nil neighbor is a
  # no-op, which is the authoritative "stop at the column's ends" — held here
  # regardless of client state (disabled chevron, swipe bounce, or arrow key).
  def handle_event("prev_card", _params, socket) do
    {:noreply, navigate_neighbor(socket, socket.assigns.prev_ref)}
  end

  def handle_event("next_card", _params, socket) do
    {:noreply, navigate_neighbor(socket, socket.assigns.next_ref)}
  end

  def handle_event("retry_card", %{"ref" => ref}, socket) do
    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
         {:ok, _card} <- Cards.retry(card, current_actor(socket)) do
      # The {:card_log_appended, ...} + {:card_upserted, ...} broadcasts update this
      # session's strip/timeline like any other subscriber's — nothing local to assign.
      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("archive_card", %{"ref" => ref}, socket) do
    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
         {:ok, archived} <- Cards.archive_card(card, current_actor(socket)) do
      {:noreply,
       socket
       |> apply_archive(archived)
       |> push_patch(to: board_path(socket.assigns))
       |> put_flash(:info, "Card archived.")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("restore_card", %{"ref" => ref}, socket) do
    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
         {:ok, _restored} <- Cards.unarchive_card(card, current_actor(socket)) do
      # unarchive broadcasts {:card_upserted, card}; this session's own
      # handle_info re-inserts the card + recomputes counts. Locally just
      # refresh the archived count, close the modal, and flash.
      {:noreply,
       socket
       |> assign_archived_count()
       |> assign(:archived_open, false)
       |> put_flash(:info, "Card restored.")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open_archived", _params, socket) do
    {:noreply,
     socket
     |> assign(:archived_open, true)
     |> assign(:archived_cards, Cards.list_archived_cards(socket.assigns.board))}
  end

  def handle_event("close_archived", _params, socket) do
    {:noreply, assign(socket, :archived_open, false)}
  end

  def handle_event("open_logs", _params, socket) do
    if connected?(socket), do: AgentLog.subscribe(socket.assigns.board.id)

    {:noreply,
     socket
     |> assign(:logs_open, true)
     |> assign(:agent_log_ids, [])
     |> stream(:agent_logs, [], reset: true)}
  end

  def handle_event("close_logs", _params, socket) do
    AgentLog.unsubscribe(socket.assigns.board.id)

    {:noreply,
     socket
     |> assign(:logs_open, false)
     |> assign(:agent_log_ids, [])
     |> stream(:agent_logs, [], reset: true)}
  end

  # A row click: close the modal and open that card — bridged to the shell in embed
  # mode (RLY-94), the URL-driven drawer otherwise.
  def handle_event("open_archived_card", %{"ref" => ref}, %{assigns: %{embed: true}} = socket) do
    {:noreply, socket |> assign(:archived_open, false) |> push_card_tap(ref)}
  end

  def handle_event("open_archived_card", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> assign(:archived_open, false)
     |> push_patch(to: card_path(socket.assigns, ref))}
  end

  # RE247 — the stalled dialog. Naming the cards is the whole point, so the list is refetched
  # at open time rather than rendered from whatever the last run-event flush cached.
  def handle_event("open_stalled", _params, socket) do
    {:noreply, socket |> assign_stalled() |> assign(stalled_open: true, stalled_error: nil)}
  end

  def handle_event("close_stalled", _params, socket) do
    {:noreply, assign(socket, stalled_open: false, stalled_error: nil)}
  end

  # A row click: close the modal and open that card — bridged to the shell in embed mode
  # (RLY-94), the URL-driven drawer otherwise. Mirrors "open_archived_card" exactly.
  def handle_event("open_stalled_card", %{"ref" => ref}, %{assigns: %{embed: true}} = socket) do
    {:noreply, socket |> assign(:stalled_open, false) |> push_card_tap(ref)}
  end

  def handle_event("open_stalled_card", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> assign(:stalled_open, false)
     |> push_patch(to: card_path(socket.assigns, ref))}
  end

  # One move path, two entry points (drag-and-drop hook and the drawer's
  # "Move to…" menu). `index` is the 0-based drop index among the target
  # stage's other cards; when omitted (drawer) the card appends to the
  # bottom. Anything that doesn't resolve on THIS board is a silent no-op.
  def handle_event("move_card", %{"ref" => ref, "stage_id" => stage_id} = params, socket) do
    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
         %Stage{} = stage <- resolve_stage(socket, stage_id),
         index when is_integer(index) <- resolve_index(params, socket, stage) do
      move_or_prompt(socket, ref, card, stage, index)
    else
      _ -> {:noreply, socket}
    end
  end

  # RE262 — a story-map drop. The client sends the target cell's column and lane keys, which
  # RelayWeb.StoryMapGrid (their one definition) decodes; the activity is derived from the task
  # by StoryMap.assign_card/2, so a drop never sends one. `index` is the 0-based slot within the
  # cell, the same contract move_card uses. Every failure is a silent no-op — an unknown ref, an
  # undecodable key, or a foreign id — the contract move_card already uses for a stale drop.
  #
  # The re-render is NOT done here: the write broadcasts {:card_upserted, card}, and this socket
  # receives its own echo, whose handle_info already runs refresh_story_map/1. One path, so a
  # second tab and the acting tab can never disagree.
  def handle_event("assign_card", %{"ref" => ref, "column" => column, "lane" => lane} = params, socket) do
    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
         {:ok, placement} <- StoryMapGrid.decode_placement(column, lane),
         {:ok, _assigned} <-
           StoryMap.assign_card(
             card,
             placement
             |> merged_drop_attrs(column, card, socket.assigns.story_tasks)
             |> Map.put(:position, parse_int(params["index"]))
           ) do
      {:noreply, socket}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("unassign_card", %{"ref" => ref}, socket) do
    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
         {:ok, _cleared} <- StoryMap.unassign_card(card) do
      # The artboard's `onTrayDrop` sets `trayOpen:true` (line ~565): a drop onto the collapsed
      # 42px rail expands it, so the card you just unmapped is visible where it landed.
      #
      # RE257 — the tray is a SHARED view setting, so this writes through put_view/3 and this
      # socket re-renders from the write's own broadcast, exactly like
      # "toggle_story_map_tray". An optimistic local assign here would be a SECOND writer of
      # one piece of state: the dropper's tray would open while every other viewer's (and the
      # persisted row) stayed collapsed, and nothing would ever reconcile them.
      log_view_write(StoryMap.put_view(socket.assigns.board, "tray_open", true), "tray_open")
      {:noreply, socket}
    else
      _other -> {:noreply, socket}
    end
  end

  # RE262 — the inline ＋ in a story-map cell. `story_map_compose` holds the open cell's
  # {column_key, lane_key}; the form is the board's own :compose_form, so one composer is open
  # anywhere on this socket at a time and "validate_card" already tracks its value server-side
  # (without that, resetting to empty_compose_form/0 below is a no-op diff and the
  # just-submitted text stays in the browser).
  def handle_event("compose_cell", %{"column" => column, "lane" => lane}, socket) do
    {:noreply,
     socket
     |> assign(:story_map_compose, {column, lane})
     |> assign(:compose_form, empty_compose_form())}
  end

  def handle_event("cancel_compose_cell", _params, socket) do
    {:noreply, assign(socket, :story_map_compose, nil)}
  end

  # Creates THEN assigns, in that order — a card must exist before it can be placed. Both writes
  # broadcast: the board's {:card_upserted, _} stream surgery puts the card in the intake column
  # live, and refresh_story_map/1 puts it in the cell. On success the composer reopens empty in
  # the same cell (Q4), so a whole cell can be typed without touching the mouse; Esc, the ✕ or a
  # click away closes it. A blank title fails Cards.create_card/3's changeset: no card is
  # created and the composer stays open showing the error.
  def handle_event("create_card_in_cell", %{"column" => column, "lane" => lane, "card" => card_params}, socket) do
    with {:ok, placement} <- StoryMapGrid.decode_placement(column, lane),
         %Stage{} = stage <- Boards.intake_stage(socket.assigns.board),
         {:ok, card} <- Cards.create_card(stage, card_params, current_actor(socket)) do
      # A soft `_ =`: the ids came off the rendered grid, so the only way this fails is a race
      # (the activity was deleted between render and submit). The card still exists in the
      # intake column and simply shows up in the tray — never a crashed LiveView.
      _ = StoryMap.assign_card(card, placement)

      {:noreply,
       socket
       |> assign(:story_map_compose, {column, lane})
       |> assign(:compose_form, empty_compose_form())}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:noreply, assign(socket, :compose_form, to_form(changeset))}
      _other -> {:noreply, socket}
    end
  end

  # RLY-217 — the user confirmed a stranding move: cancel the run (frees its executor slot via the
  # existing revoke/release path) THEN apply the now-safe move. After cancel the run is terminal,
  # so move_card no longer refuses. cancel_run/1 logs the "run cancelled" timeline entry.
  def handle_event("confirm_move", _params, %{assigns: %{pending_move: %{} = pm}} = socket) do
    socket = assign(socket, :pending_move, nil)

    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, pm.ref),
         %Stage{} = stage <- resolve_stage(socket, pm.target_stage_id),
         %Run{} = run <- Runs.get_run(pm.run_id) do
      _ = Runs.cancel_run(run)

      case Cards.move_card(card, stage, pm.index, current_actor(socket)) do
        {:ok, moved} -> {:noreply, apply_move(socket, card.stage_id, moved)}
        _error -> {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("confirm_move", _params, socket), do: {:noreply, socket}

  # RLY-217 — the user declined: the card never moved. Clear the intent and restream the affected
  # lanes so the board is pristine (belt-and-suspenders; the DnD hook never mutates the DOM list).
  def handle_event("cancel_move", _params, %{assigns: %{pending_move: %{} = pm}} = socket) do
    {:noreply,
     socket
     |> assign(:pending_move, nil)
     |> restream_lanes([pm.source_stage_id, pm.target_stage_id])}
  end

  def handle_event("cancel_move", _params, socket), do: {:noreply, socket}

  # MMF 12c — clicking a collapsed stage strip force-opens it for this session only
  # (a MapSet in the socket; not persisted, not broadcast). RLY-111: also clears any
  # session re-collapse, so force_open and stage_force_closed never both hold one id.
  # RLY-145: restream everything the expand reveals — stream items are consumed at
  # render time, so cards streamed while the stage was collapsed never reached the
  # DOM and the revealed containers would otherwise come up empty.
  def handle_event("expand_stage", %{"stage-id" => stage_id}, socket) do
    case resolve_stage(socket, stage_id) do
      nil ->
        {:noreply, socket}

      %Stage{id: id} ->
        {:noreply,
         socket
         |> update(:stage_force_closed, &MapSet.delete(&1, id))
         |> update(:force_open, &MapSet.put(&1, id))
         |> restream_lanes([id | sublane_ids(socket, id)])}
    end
  end

  # RLY-94 — the BoardPager hook reports whether the phone-width pager is active
  # (below --breakpoint-drawer). In pager mode every stage renders as a full snap
  # page: stage collapse (RLY-111) is a desktop-only behavior.
  def handle_event("pager", %{"active" => active}, socket) when is_boolean(active) do
    {:noreply, assign(socket, :pager_mode, active)}
  end

  # RLY-111/RLY-145 — clicking an expanded stage's name collapses it for this
  # session, without a reload. Works on every stage; complementary to expand_stage.
  def handle_event("collapse_stage", %{"stage-id" => stage_id}, socket) do
    case parse_int(stage_id) do
      nil ->
        {:noreply, socket}

      id ->
        {:noreply,
         socket
         |> update(:force_open, &MapSet.delete(&1, id))
         |> update(:stage_force_closed, &MapSet.put(&1, id))}
    end
  end

  # RLY-1 items 2 & 3 — a lane header/strip click flips that lane's collapse state
  # for this session only. force_open and force_closed are complementary: entering
  # one clears the other, so a lane is never forced both ways at once.
  def handle_event("toggle_collapse", %{"stage-id" => stage_id}, socket) do
    case resolve_stage(socket, stage_id) do
      %Stage{id: id, parent_id: parent_id, type: type} ->
        lane = if is_nil(parent_id), do: :main, else: type

        collapsed? =
          lane_collapsed?(id, lane, socket.assigns.stage_counts, socket.assigns.force_open, socket.assigns.force_closed)

        socket =
          if collapsed? do
            # RLY-145: refetch the lane being revealed — see expand_stage.
            socket
            |> update(:force_closed, &MapSet.delete(&1, id))
            |> update(:force_open, &MapSet.put(&1, id))
            |> restream_lanes([id])
          else
            socket
            |> update(:force_open, &MapSet.delete(&1, id))
            |> update(:force_closed, &MapSet.put(&1, id))
          end

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("edit_title", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    {:noreply,
     socket
     |> assign(:editing_title, true)
     |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))}
  end

  def handle_event("edit_title", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_title", _params, socket) do
    {:noreply, assign(socket, :editing_title, false)}
  end

  def handle_event("save_card_title", %{"card" => card_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Cards.update_card(card, card_params) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:editing_title, false)
         |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :title_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_title", _params, socket), do: {:noreply, socket}

  def handle_event("edit_tag", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    {:noreply,
     socket
     |> assign(:editing_tag, true)
     |> assign(:tag_form, to_form(%{"tag" => card.tag || ""}, as: :card))
     |> assign(:tag_suggestions, Cards.list_board_tags(socket.assigns.board.id))}
  end

  def handle_event("edit_tag", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_tag", _params, socket) do
    {:noreply, assign(socket, editing_tag: false, tag_form: nil)}
  end

  def handle_event("save_card_tag", %{"card" => card_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Cards.update_card(card, card_params) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:editing_tag, false)
         |> assign(:tag_form, nil)
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :tag_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_tag", _params, socket), do: {:noreply, socket}

  def handle_event("edit_description", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    {:noreply,
     socket
     |> assign(:editing_description, true)
     |> assign(:description_form, to_form(%{"description" => card.description || ""}, as: :card))}
  end

  def handle_event("edit_description", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_description", _params, socket) do
    {:noreply, assign(socket, editing_description: false, description_form: nil)}
  end

  def handle_event(
        "save_card_description",
        %{"card" => card_params},
        %{assigns: %{selected_card: %Card{} = card}} = socket
      ) do
    case Cards.update_card(card, card_params) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:editing_description, false)
         |> assign(:description_form, nil)
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :description_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_description", _params, socket), do: {:noreply, socket}

  def handle_event("start_public_desc", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    {:noreply,
     socket
     |> assign(:editing_public_desc, true)
     |> assign(:public_desc_form, to_form(%{"public_description" => card.public_description || ""}))}
  end

  def handle_event("cancel_public_desc", _params, socket) do
    {:noreply, assign(socket, :editing_public_desc, false)}
  end

  def handle_event(
        "save_public_desc",
        %{"public_description" => text},
        %{assigns: %{selected_card: %Card{} = card}} = socket
      ) do
    {:ok, updated} = Cards.set_public_description(card, text)

    {:noreply,
     socket
     |> assign(:selected_card, updated)
     |> assign(:editing_public_desc, false)}
  end

  def handle_event("edit_acceptance_criteria", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    {:noreply,
     socket
     |> assign(:editing_acceptance_criteria, true)
     |> assign(
       :acceptance_criteria_form,
       to_form(%{"acceptance_criteria" => card.acceptance_criteria || ""}, as: :card)
     )}
  end

  def handle_event("edit_acceptance_criteria", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_acceptance_criteria", _params, socket) do
    {:noreply, assign(socket, editing_acceptance_criteria: false, acceptance_criteria_form: nil)}
  end

  def handle_event(
        "save_card_acceptance_criteria",
        %{"card" => card_params},
        %{assigns: %{selected_card: %Card{} = card}} = socket
      ) do
    case Cards.update_card(card, Map.take(card_params, ["acceptance_criteria"])) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:editing_acceptance_criteria, false)
         |> assign(:acceptance_criteria_form, nil)
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :acceptance_criteria_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_acceptance_criteria", _params, socket), do: {:noreply, socket}

  def handle_event("edit_spec", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    {:noreply,
     socket
     |> assign(:editing_spec, true)
     |> assign(:spec_form, to_form(%{"spec" => card.spec || ""}, as: :card))}
  end

  def handle_event("edit_spec", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_spec", _params, socket) do
    {:noreply, assign(socket, editing_spec: false, spec_form: nil)}
  end

  def handle_event("save_card_spec", %{"card" => card_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Cards.update_card(card, Map.take(card_params, ["spec"])) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:editing_spec, false)
         |> assign(:spec_form, nil)
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :spec_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_spec", _params, socket), do: {:noreply, socket}

  def handle_event("edit_plan", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    {:noreply,
     socket
     |> assign(:editing_plan, true)
     |> assign(:plan_form, to_form(%{"plan" => card.plan || ""}, as: :card))}
  end

  def handle_event("edit_plan", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_plan", _params, socket) do
    {:noreply, assign(socket, editing_plan: false, plan_form: nil)}
  end

  def handle_event("save_card_plan", %{"card" => card_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Cards.update_card(card, Map.take(card_params, ["plan"])) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:editing_plan, false)
         |> assign(:plan_form, nil)
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :plan_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_plan", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_acceptance_criteria", _params, socket) do
    {:noreply, update(socket, :expanded_acceptance_criteria?, &(!&1))}
  end

  def handle_event("toggle_spec", _params, socket) do
    {:noreply, update(socket, :expanded_spec?, &(!&1))}
  end

  def handle_event("toggle_plan", _params, socket) do
    {:noreply, update(socket, :expanded_plan?, &(!&1))}
  end

  # RE257 — the tray's open state is SHARED board-wide, so the click writes through
  # Relay.StoryMap.toggle_view/2 and assigns nothing here: the write's own broadcast lands in
  # this socket's mailbox too (local PubSub dispatch is synchronous in the writer's process) and
  # re-assigns in handle_info/2. One path, so the clicker and every other viewer can never
  # disagree. toggle_view/2 rather than put_view/3 with `not assigns...`: the assign lags a
  # render behind, so two fast clicks would both flip from the same stale value (see its doc).
  # Still deliberately OUTSIDE the read_only? guard list — view state is not board data, so it
  # stays live on an archived board, whose map is still readable.
  def handle_event("toggle_story_map_tray", _params, socket) do
    log_view_write(StoryMap.toggle_view(socket.assigns.board, "tray_open"), "tray_open")
    {:noreply, socket}
  end

  # RE260 — the two view-only chrome controls, shared board-wide for the same reason the tray is
  # (both change grid GEOMETRY, which raw-pixel cursors are measured in). `parse_zoom/1` is the
  # ONLY parser for the closed set and never calls String.to_atom/1, so a forged value is a
  # silent no-op rather than a new atom — and it still guards the wire value BEFORE the write.
  # Neither event is in the read_only? guard above, for the reason above the tray toggle.
  def handle_event("set_story_map_zoom", %{"zoom" => zoom}, socket) do
    case StoryMapComponents.parse_zoom(zoom) do
      {:ok, level} ->
        log_view_write(StoryMap.put_view(socket.assigns.board, "zoom", Atom.to_string(level)), "zoom")
        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_story_map_hide_tasks", _params, socket) do
    log_view_write(StoryMap.toggle_view(socket.assigns.board, "hide_tasks"), "hide_tasks")
    {:noreply, socket}
  end

  # RE259 — the filter bar and the two view-narrowing controls. All six are shared view
  # writes: the wire value is parsed BEFORE the write and a value this board does not have is
  # a silent no-op (`set_story_map_zoom`'s pattern), and none of them is in the read_only?
  # guard list, for the reason written above `toggle_story_map_tray` — view state is not
  # board data, so it stays live on an archived board.
  def handle_event("toggle_story_map_owner_filter", %{"owner" => owner}, socket) do
    case StoryMapFilter.parse_owner_key(owner) do
      {:ok, parsed} ->
        # parse |> owner_key NORMALIZES, so "u:007" can only ever be stored as "u:7".
        log_view_write(
          StoryMap.toggle_view_member(
            socket.assigns.board,
            "owner_filter",
            StoryMapFilter.owner_key(parsed)
          ),
          "owner_filter"
        )

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_story_map_needs_filter", _params, socket) do
    log_view_write(
      StoryMap.toggle_view(socket.assigns.board, "needs_input_filter"),
      "needs_input_filter"
    )

    {:noreply, socket}
  end

  # One write, one broadcast: `Clear` must never leave a half-cleared bar visible.
  def handle_event("clear_story_map_filters", _params, socket) do
    log_view_write(
      StoryMap.merge_view(socket.assigns.board, %{
        "owner_filter" => [],
        "needs_input_filter" => false
      }),
      "filters"
    )

    {:noreply, socket}
  end

  def handle_event("toggle_story_map_collapse", %{"activity-id" => activity_id}, socket) do
    case find_story_activity(socket, activity_id) do
      nil ->
        {:noreply, socket}

      activity ->
        # The artboard's `toggleCollapse` clears focus in the SAME update (line ~659), and it
        # must: while focusing, ▾ on the focused band is the only expanded activity.
        log_view_write(
          StoryMap.toggle_view_member(
            socket.assigns.board,
            "collapsed",
            activity.id,
            %{"focus" => nil}
          ),
          "collapsed"
        )

        {:noreply, socket}
    end
  end

  # The artboard's `setFocusEv` (line ~661): focusing the already-focused activity exits.
  # Computed from the assign rather than the committed row, unlike the toggles above,
  # because the two-fast-clicks outcome here is benign — both clicks land on "focus this
  # one", which is what a double-click means — where a lost boolean flip is a dead button.
  def handle_event("set_story_map_focus", %{"activity-id" => activity_id}, socket) do
    case find_story_activity(socket, activity_id) do
      nil ->
        {:noreply, socket}

      activity ->
        focus = if socket.assigns.story_map_focus == activity.id, do: nil, else: activity.id
        log_view_write(StoryMap.merge_view(socket.assigns.board, %{"focus" => focus}), "focus")
        {:noreply, socket}
    end
  end

  def handle_event("clear_story_map_focus", _params, socket) do
    log_view_write(StoryMap.merge_view(socket.assigns.board, %{"focus" => nil}), "focus")
    {:noreply, socket}
  end

  # RE257 — one cursor frame from this socket's pointer. Gated on the story map (interview
  # decision 3: only people viewing the map have a cursor), floored per socket, and relayed
  # through Relay.Presence's cursor topic — never Relay.Events, which would bump the board
  # version 20 times a second. Deliberately OUTSIDE the read_only? guard list, like
  # toggle_story_map_tray/set_story_map_zoom above — a cursor changes no card data, so it stays
  # live on an archived (read-only) board too.
  def handle_event("cursor_moved", %{"x" => x, "y" => y}, socket) when is_number(x) and is_number(y) do
    now = System.monotonic_time(:millisecond)

    cond do
      socket.assigns.live_action != :story_map ->
        {:noreply, socket}

      now - socket.assigns.cursor_last_ms < @cursor_floor_ms ->
        {:noreply, socket}

      true ->
        Presence.broadcast_cursor(
          socket.assigns.board.id,
          socket.assigns.current_scope.user,
          round(x),
          round(y)
        )

        {:noreply, assign(socket, :cursor_last_ms, now)}
    end
  end

  # A malformed frame is a silent no-op, never a crash: this is client input on a 20Hz path.
  def handle_event("cursor_moved", _params, socket), do: {:noreply, socket}

  # Also deliberately outside the read_only? guard list — see cursor_moved/3 above.
  def handle_event("cursor_left", _params, socket) do
    if socket.assigns.live_action == :story_map do
      Presence.broadcast_cursor_gone(socket.assigns.board.id, socket.assigns.current_scope.user.id)
    end

    {:noreply, socket}
  end

  # RE263 — the three create affordances. Opening a draft replaces any other open one; the
  # discarded draft creates nothing.
  def handle_event("story_map_add_activity", _params, socket) do
    {:noreply, open_story_map_draft(socket, :activity)}
  end

  def handle_event("story_map_add_task", %{"activity-id" => activity_id}, socket) do
    case find_story_activity(socket, activity_id) do
      nil -> {:noreply, socket}
      activity -> {:noreply, open_story_map_draft(socket, {:task, activity.id})}
    end
  end

  def handle_event("story_map_add_release", _params, socket) do
    {:noreply, open_story_map_draft(socket, :release)}
  end

  # Every keystroke, for the same reason validate_card exists: without the server's own copy of
  # the text there is nothing to diff against when the input has to come back empty.
  def handle_event("story_map_draft_change", %{"name" => name}, socket) do
    {:noreply, assign(socket, :story_map_draft_name, name)}
  end

  def handle_event("story_map_draft_submit", %{"name" => name}, socket) do
    {:noreply, commit_story_map_draft(socket, socket.assigns.story_map_draft, String.trim(name))}
  end

  # Escape and clicking away both land here — NOT blur, which LiveView fires itself around
  # every submit and would use to cancel the draft it is about to commit (see
  # `inline_name_input/1`). A no-op when no draft is open.
  def handle_event("story_map_draft_cancel", _params, socket) do
    {:noreply, close_story_map_draft(socket)}
  end

  # RE261 — the inline rename. `kind` and `id` arrive as strings and are resolved against the
  # ALREADY board-scoped assigns, never by id from the database — the rule story_map_add_task
  # established. An unknown kind or a forged id resolves to nil and the event is a no-op.
  def handle_event("story_map_rename_start", %{"kind" => kind, "id" => id}, socket) do
    case resolve_story_map_target(socket, kind, id) do
      {kind_atom, record} -> {:noreply, open_story_map_edit(socket, {kind_atom, record.id}, record.name)}
      nil -> {:noreply, socket}
    end
  end

  # Every keystroke, for the same reason story_map_draft_change exists: LiveView only patches an
  # input whose server-rendered value changed.
  def handle_event("story_map_rename_change", %{"name" => name}, socket) do
    {:noreply, assign(socket, :story_map_edit_name, name)}
  end

  def handle_event("story_map_rename_submit", %{"name" => name}, socket) do
    {:noreply, commit_story_map_rename(socket, socket.assigns.story_map_edit, String.trim(name))}
  end

  # Escape and clicking away both land here — NOT blur, for the reason inline_name_input/1
  # documents at length. A no-op when no rename is open.
  def handle_event("story_map_rename_cancel", _params, socket) do
    {:noreply, close_story_map_edit(socket)}
  end

  # RE261 — the ✕. The rendered button is `disabled` while the structure holds cards, so this
  # is reachable only by a forged event or by a card assigned between render and click; the
  # context refuses either way and the flash is the defence-in-depth message. The re-render
  # comes from the delete's own {:story_map_changed, _} broadcast, like every other structure
  # write on this page.
  def handle_event("story_map_delete", %{"kind" => kind, "id" => id}, socket) do
    case resolve_story_map_target(socket, kind, id) do
      {kind_atom, record} -> {:noreply, apply_story_map_delete(socket, delete_structure(kind_atom, record))}
      nil -> {:noreply, socket}
    end
  end

  # RE261 — a header drop. The client sends IDS ONLY; the server resolves both ends from its
  # board-scoped assigns, computes the new order with StoryMap.insert_before/3 and calls the
  # context, so a forged payload can at worst reorder something the user can already see. Every
  # failure is a silent no-op — the contract assign_card already uses for a stale drop. The
  # re-render comes from the write's own {:story_map_changed, _} broadcast.
  def handle_event(
        "story_map_reorder",
        %{"kind" => kind, "id" => id, "target_kind" => target_kind, "target_id" => target_id},
        socket
      ) do
    with {_kind, _record} = dragged <- resolve_story_map_target(socket, kind, id),
         {_target_kind, _target} = target <- resolve_story_map_target(socket, target_kind, target_id) do
      {:noreply, apply_story_map_reorder(socket, dragged, target)}
    else
      _other -> {:noreply, socket}
    end
  end

  # SUB-TASKS panel toggle (RLY-18): flip the item's done flag and refresh the
  # drawer + board card so the done/total count and stage badge stay in sync.
  def handle_event("toggle_sub_task", %{"id" => id}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    with %{id: sub_task_id, done: done} <- Enum.find(card.sub_tasks, &(to_string(&1.id) == id)),
         {:ok, updated} <- Cards.set_sub_task_done(card, sub_task_id, !done) do
      {:noreply, refresh_card(socket, updated)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_sub_task", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_reassign", _params, socket) do
    {:noreply, update(socket, :reassign_open, &(not &1))}
  end

  # RLY-32: any board member (or the agent) can be assigned — the old
  # "only yourself" restriction is lifted. A non-member {:user, id} is a no-op.
  def handle_event("add_owner", params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case resolve_actor(params) do
      :agent ->
        apply_owner_change(socket, Cards.add_owner(card, :agent, current_actor(socket)))

      {:user, id} = actor ->
        if member_user_id?(socket, id) do
          apply_owner_change(socket, Cards.add_owner(card, actor, current_actor(socket)))
        else
          {:noreply, socket}
        end

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("add_owner", _params, socket), do: {:noreply, socket}

  def handle_event("remove_owner", params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case resolve_actor(params) do
      nil -> {:noreply, socket}
      actor -> apply_owner_change(socket, Cards.remove_owner(card, actor, current_actor(socket)))
    end
  end

  def handle_event("remove_owner", _params, socket), do: {:noreply, socket}

  def handle_event("validate_comment", %{"comment" => comment_params}, socket) do
    {:noreply, assign(socket, :comment_form, to_form(comment_params, as: :comment))}
  end

  def handle_event("post_comment", %{"comment" => comment_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Activity.add_comment(card, %{actor: current_actor(socket), body: comment_params["body"]}) do
      # `add_comment` broadcasts `:timeline_appended`, and this LiveView is subscribed to
      # its own board topic, so `handle_info/2` below inserts the note again for every
      # viewer, this one included. Insert it locally anyway: `Relay.Events.broadcast/2` is
      # fire-and-forget, so relying on the echo alone would let a dropped broadcast leave
      # the author's own note missing from their own drawer. Both `insert_note/2` and the
      # stream are idempotent per note id, so the echo is a no-op.
      {:ok, comment} ->
        {:noreply,
         socket
         |> insert_note(comment)
         |> assign(:comment_form, empty_comment_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset))}
    end
  end

  def handle_event("post_comment", _params, socket), do: {:noreply, socket}

  # MMF 14 — the drawer's amber panel submits the human's answer: log it,
  # return the baton (working on an AI-meant stage, queued otherwise), and
  # clear the block. Attributed to the signed-in user; refresh_card re-streams
  # the board card so the amber badge flips off (and MMF 18 broadcasts do the
  # same everywhere else).
  def handle_event(
        "answer_input",
        %{"answer" => %{"body" => body}},
        %{assigns: %{selected_card: %Card{status: :needs_input} = card}} = socket
      ) do
    case Cards.answer_input(card, body, current_actor(socket)) do
      {:ok, card} -> {:noreply, after_answer(socket, card)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("answer_input", _params, socket), do: {:noreply, socket}

  # RLY-71 — stepper: record a picked option for the current step (single-select).
  #
  # phx-value-option, not phx-value-value: "value" collides with the button's intrinsic DOM
  # .value property (empty for a value-less <button>), which wins over the phx-value-*
  # attribute when a real browser serializes the click.
  def handle_event(
        "answer_select",
        %{"index" => index, "option" => option},
        %{assigns: %{selected_card: %Card{status: :needs_input}}} = socket
      ) do
    step = String.to_integer(index)
    {:noreply, assign(socket, :answer_values, Map.put(socket.assigns.answer_values, step, option))}
  end

  def handle_event("answer_select", _params, socket), do: {:noreply, socket}

  # RLY-71 — stepper: a typed custom answer for the current step. Blank clears the step so Next
  # stays disabled until the human picks or types something.
  def handle_event(
        "answer_custom",
        %{"answer" => %{"index" => index, "text" => text}},
        %{assigns: %{selected_card: %Card{status: :needs_input}}} = socket
      ) do
    step = String.to_integer(index)

    values =
      if String.trim(text) == "",
        do: Map.delete(socket.assigns.answer_values, step),
        else: Map.put(socket.assigns.answer_values, step, text)

    {:noreply, assign(socket, :answer_values, values)}
  end

  def handle_event("answer_custom", _params, socket), do: {:noreply, socket}

  # RLY-71 — stepper navigation, clamped to the question range.
  def handle_event("answer_next", _params, %{assigns: %{selected_card: %Card{status: :needs_input}}} = socket) do
    %{answer_questions: questions, answer_step: step} = socket.assigns
    {:noreply, assign(socket, :answer_step, min(step + 1, length(questions) - 1))}
  end

  def handle_event("answer_next", _params, socket), do: {:noreply, socket}

  def handle_event(
        "answer_back",
        _params,
        %{assigns: %{selected_card: %Card{status: :needs_input}, answer_step: step}} = socket
      ) do
    {:noreply, assign(socket, :answer_step, max(step - 1, 0))}
  end

  def handle_event("answer_back", _params, socket), do: {:noreply, socket}

  def handle_event(
        "answer_goto",
        %{"index" => index},
        %{assigns: %{selected_card: %Card{status: :needs_input}, answer_questions: questions}} = socket
      ) do
    step = index |> String.to_integer() |> max(0) |> min(length(questions) - 1)
    {:noreply, assign(socket, :answer_step, step)}
  end

  def handle_event("answer_goto", _params, socket), do: {:noreply, socket}

  # RLY-71 — submit the batch: compose one numbered Q->A comment and reuse Cards.answer_input/3,
  # which records the comment, resumes the card, and logs one :input_answered (unchanged contract).
  def handle_event(
        "answer_submit",
        _params,
        %{
          assigns: %{
            selected_card: %Card{status: :needs_input} = card,
            answer_questions: questions,
            answer_values: values
          }
        } = socket
      ) do
    case Cards.answer_input(card, Cards.compose_answer(questions, values), current_actor(socket)) do
      {:ok, updated} -> {:noreply, after_answer(socket, updated)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("answer_submit", _params, socket), do: {:noreply, socket}

  # RLY-189 — re-enter a terminally failed run at the node that died. Acts on the
  # run this socket already has in `:card_runs` (the one whose banner is on screen)
  # rather than re-querying "the latest run": a run started by someone else between
  # render and click must surface as `retry_run/2`'s :active_run_exists refusal, not
  # silently retry a run the human never looked at. The run's own {:run_resumed, _} /
  # {:node_started, _} broadcasts refresh every OTHER session; the acting socket
  # re-reads synchronously so the banner clears in the same round-trip.
  def handle_event("retry_run", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case List.first(socket.assigns.card_runs) do
      nil ->
        {:noreply, put_flash(socket, :error, "This card has no run to retry.")}

      run ->
        case Runs.retry_run(run, actor: current_actor(socket)) do
          {:ok, _run} ->
            {:noreply, assign(socket, :card_runs, Runs.list_runs_for_card(card))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Runs.retry_refusal_message(reason))}
        end
    end
  end

  def handle_event("retry_run", _params, socket), do: {:noreply, socket}

  # RE247 — one row's Restart. The ref is resolved through THIS board (never a client-supplied
  # run id), then revived through retry_run/2 — the identical path the drawer's retry and the
  # API's bulk sweep use, so its guards (active run, executor liveness, genuine-question
  # refusal) still apply and refuse by name. An unknown ref, or a card with no run at all, is
  # a silent no-op like move_card. revive_run's {:run_resumed, _} broadcast refreshes every
  # other session; this socket recomputes synchronously so the row leaves the list in the same
  # round-trip.
  def handle_event("restart_one", %{"ref" => ref}, socket) do
    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
         %Run{} = run <- Runs.latest_run_for_retry(card) do
      {:noreply, after_restart_one(socket, ref, Runs.retry_run(run, actor: current_actor(socket)))}
    else
      _missing -> {:noreply, socket}
    end
  end

  # MMF 15 — the drawer's green review panel: the four human review actions,
  # each a thin wrapper over an existing context transition (Cards.approve/
  # reject from MMF 13, set_status/add_owner from MMF 06), attributed to the
  # signed-in user. Approve/reject move the card, so the acting session
  # re-streams the source and target columns synchronously; MMF 18 echoes
  # keep every other session in sync.
  def handle_event("review_approve", _params, %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket) do
    case Cards.approve(card, current_actor(socket)) do
      {:ok, updated} -> {:noreply, after_review_decision(socket, card, updated)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("review_approve", _params, socket), do: {:noreply, socket}

  def handle_event("review_open_reject", _params, socket) do
    {:noreply, assign(socket, reject_open: true, reject_form: empty_reject_form(), reject_error: nil)}
  end

  def handle_event("review_cancel_reject", _params, socket) do
    {:noreply, assign(socket, reject_open: false, reject_error: nil)}
  end

  def handle_event(
        "review_reject",
        %{"reject" => %{"note" => note} = params},
        %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket
      ) do
    if String.trim(note) == "" do
      {:noreply,
       assign(socket,
         reject_form: to_form(params, as: :reject),
         reject_error: "Add a note — the AI needs to know what to change."
       )}
    else
      case Cards.reject(card, note, current_actor(socket)) do
        {:ok, updated} -> {:noreply, after_review_decision(socket, card, updated)}
        {:error, _reason} -> {:noreply, socket}
      end
    end
  end

  def handle_event("review_reject", _params, socket), do: {:noreply, socket}

  # RLY-47 — "Take over": flip ownership to the signed-in user (drops the AI via the
  # exclusivity invariant). Status is untouched — provenance changes, not the baton's substate.
  def handle_event("take_over", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    apply_owner_change(socket, Cards.take_over(card, current_actor(socket)))
  end

  def handle_event("take_over", _params, socket), do: {:noreply, socket}

  # RLY-137 — the drawer's Detail | Run | Activity tab bar: a local assign, no server
  # round trip beyond the click itself.
  def handle_event("drawer_tab", %{"tab" => tab}, socket) when tab in ~w(detail run activity) do
    {:noreply, assign(socket, :drawer_tab, String.to_existing_atom(tab))}
  end

  # MMF 18 — realtime application of Relay.Events broadcasts. Every open
  # session applies every event for its board, including the acting
  # session's own echo: streams upsert by DOM id and counts/stages are
  # recomputed from the DB, so double-apply is a no-op by construction.
  @impl true
  def handle_info({:card_upserted, %Card{} = card}, socket) do
    if find_stage_by_id(socket, card.stage_id) do
      cards_by_stage = socket.assigns.board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

      {:noreply,
       socket
       |> refresh_card_health(card.id)
       |> assign(:needs_input_questions, Cards.needs_input_questions(socket.assigns.board))
       |> upsert_card_stream(card, cards_by_stage)
       |> assign(:stage_counts, stage_counts(socket.assigns.board.stages, cards_by_stage))
       |> assign_archived_count()
       |> refresh_face_runs(cards_by_stage)
       |> maybe_refresh_drawer(card)
       |> refresh_story_map()}
    else
      # The card sits in a stage this socket hasn't loaded yet (e.g. a
      # just-enabled sub-lane racing its stages_changed event): rebuild.
      {:noreply, reload_board(socket)}
    end
  end

  def handle_info({:card_moved, %Card{} = moved, from_stage_id}, socket) do
    if find_stage_by_id(socket, moved.stage_id) do
      cards_by_stage = socket.assigns.board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

      {:noreply,
       socket
       |> refresh_card_health(moved.id)
       |> apply_move(from_stage_id, moved)
       |> refresh_face_runs(cards_by_stage)
       |> refresh_story_map()}
    else
      {:noreply, reload_board(socket)}
    end
  end

  # RLY-4 — a card was archived elsewhere: drop it from its column here too
  # (idempotent on the acting session's own echo) and close this session's
  # drawer if the archived card is the one open here.
  def handle_info({:card_archived, %Card{} = card}, socket) do
    if find_stage_by_id(socket, card.stage_id) do
      {:noreply, socket |> apply_archive(card) |> close_drawer_if_selected(card) |> refresh_story_map()}
    else
      {:noreply, reload_board(socket)}
    end
  end

  def handle_info({:timeline_appended, card_id, entry}, socket) do
    case socket.assigns.selected_card do
      %Card{id: ^card_id} = card ->
        {:noreply, socket |> insert_timeline_entry(entry) |> refresh_needs_input_question(card, entry)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info({:stages_changed, _board_id}, socket) do
    {:noreply, reload_board(socket)}
  end

  # RE265/RE264 — the story map is a second lens onto the same board and rides the shared
  # "board:<id>" topic, so this socket receives the event even when it is rendering the kanban
  # view. refresh_story_map/1 no-ops off the story map, so an open board pays nothing; a clause
  # is required either way (LiveView dispatches every message here, and an unmatched one is a
  # FunctionClauseError that kills the LiveView).
  def handle_info({:story_map_changed, _board_id}, socket), do: {:noreply, refresh_story_map(socket)}

  # RE257 — the roster changed. Re-derived from Relay.Presence rather than patched from the diff
  # payload: the payload counts TABS, the stack counts PEOPLE. A leaving tab clears that
  # person's cursor only when the fresh roster says they are actually gone — closing one of
  # three tabs must not blank a cursor the other two are still driving.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: payload}, socket) do
    people = Presence.list_people(socket.assigns.board.id)
    present = MapSet.new(people, & &1.user_id)

    socket =
      payload
      |> Map.get(:leaves, %{})
      |> Map.keys()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reject(&MapSet.member?(present, &1))
      |> Enum.reduce(socket, &push_event(&2, "story_map_cursor_gone", %{user_id: &1}))

    {:noreply, assign(socket, :presence_people, people)}
  end

  # RE257 — a shared view setting changed, here or in someone else's tab. The whole view arrives
  # in the payload, so there is nothing to refetch.
  def handle_info({:story_map_view_changed, _board_id, view}, socket) do
    {:noreply, assign_story_map_view(socket, view)}
  end

  # RE257 — someone else's pointer. push_event/3 rather than an assign: it sends no template
  # diff, so a 20Hz stream costs nothing but the message. Your OWN frames are skipped, so two
  # tabs of one person never see a ghost of themselves. The colour is derived here, from the
  # sender's email, so the cursor and that person's avatar are provably the same hue.
  def handle_info({:story_map_cursor, user_id, name, email, x, y}, socket) do
    if user_id == socket.assigns.current_scope.user.id do
      {:noreply, socket}
    else
      {:noreply,
       push_event(socket, "story_map_cursor", %{
         user_id: user_id,
         name: name,
         color: identity_color(email),
         x: x,
         y: y
       })}
    end
  end

  def handle_info({:story_map_cursor_gone, user_id}, socket) do
    {:noreply, push_event(socket, "story_map_cursor_gone", %{user_id: user_id})}
  end

  # RLY-69 — a vote toggled somewhere (this board, the public board, another
  # session). Refresh the affected card's count (and, if its drawer is open,
  # the supporters block), then re-stream the card so its face badge repaints
  # with the new @vote_counts value — mirrors the {:card_upserted, …} idiom.
  def handle_info({:vote_changed, card_id}, socket) do
    counts = Map.put(socket.assigns.vote_counts, card_id, Votes.count(card_id))
    socket = assign(socket, :vote_counts, counts)

    socket =
      case socket.assigns.selected_card do
        %Card{id: ^card_id} = card ->
          {supporters, total} = Votes.supporters(card, 5)
          assign(socket, drawer_supporters: supporters, drawer_vote_count: total)

        _ ->
          socket
      end

    case Cards.get_card(socket.assigns.board, card_id) do
      %Card{} = card -> {:noreply, stream_insert(socket, stream_name(card.stage_id), card)}
      _ -> {:noreply, socket}
    end
  end

  # RLY-204 — every run event names exactly one card. Rather than refetch the whole board
  # (Cards.list_cards/1 + Runs.run_summaries_for_board/1) per event per session, funnel each
  # into mark_run_dirty/2: accumulate the dirty card_id and arm a single ~150ms debounce timer.
  # The burst flushes once, scoped to the cards that changed (handle_info(:flush_run_changes, …)).
  #
  # The engine's fine-grained events (Relay.Runs.Listener / Relay.Runs.RunServer broadcast on the
  # same `board:<id>:runs` topic as the coarse {:run_changed, card_id}) all carry the %Run{} that
  # changed, so each just contributes its card_id to the dirty set.
  def handle_info({:run_changed, card_id}, socket), do: {:noreply, mark_run_dirty(socket, card_id)}

  def handle_info({:run_started, %Run{card_id: card_id}}, socket), do: {:noreply, mark_run_dirty(socket, card_id)}

  def handle_info({:run_parked, %Run{card_id: card_id}}, socket), do: {:noreply, mark_run_dirty(socket, card_id)}

  def handle_info({:run_resumed, %Run{card_id: card_id}}, socket), do: {:noreply, mark_run_dirty(socket, card_id)}

  def handle_info({:run_finished, %Run{card_id: card_id}}, socket), do: {:noreply, mark_run_dirty(socket, card_id)}

  def handle_info({:node_started, %Run{card_id: card_id}, _execution}, socket),
    do: {:noreply, mark_run_dirty(socket, card_id)}

  def handle_info({:node_finished, %Run{card_id: card_id}, _execution}, socket),
    do: {:noreply, mark_run_dirty(socket, card_id)}

  # RLY-204 — flush the coalesced burst: refetch ONLY the dirty cards' summaries/faces, restream
  # each, and refresh the open drawer's timeline when its card is dirty. This replaces the old
  # per-event Cards.list_cards/1 + Runs.run_summaries_for_board/1 + refresh_face_runs/2 whole-board
  # refetch. Emits [:relay, :board, :run_flush] with the coalescing win in numbers.
  def handle_info(:flush_run_changes, socket) do
    board = socket.assigns.board
    dirty = socket.assigns.dirty_run_cards
    flows = socket.assigns.flows

    socket = Enum.reduce(dirty, socket, &flush_dirty_card(&2, &1, board, flows))

    :telemetry.execute(
      [:relay, :board, :run_flush],
      %{card_count: MapSet.size(dirty), event_count: socket.assigns.run_flush_events},
      %{board_id: board.id}
    )

    {:noreply,
     socket
     |> assign_stalled()
     |> assign(:dirty_run_cards, MapSet.new())
     |> assign(:run_flush_events, 0)
     |> assign(:run_flush_pending?, false)}
  end

  # RLY-10 — a board rename (this or another session): retitle live. The
  # broadcast board carries no preloaded stages, so merge just the name onto
  # the already-loaded @board (the open drawer reads @board.stages).
  def handle_info({:board_updated, %Board{} = board}, socket) do
    updated = %{socket.assigns.board | name: board.name, archived_at: board.archived_at}

    {:noreply,
     socket
     |> assign(:board, updated)
     |> assign(:page_title, board.name)
     |> assign(:read_only?, Board.archived?(updated))}
  end

  # RLY-32: a member was removed elsewhere — eject the affected session's open
  # board (access is revoked); every other open session just refreshes its
  # reassign-picker member list.
  def handle_info({:member_removed, user_id}, socket) do
    if socket.assigns.current_scope.user.id == user_id do
      {:noreply,
       socket
       |> put_flash(:info, "You were removed from this board.")
       |> push_navigate(to: ~p"/boards")}
    else
      {:noreply, assign(socket, :members, Members.list_members(socket.assigns.board))}
    end
  end

  @impl true
  def handle_info({:agent_log, entry}, socket) do
    {kept, dropped} = Enum.split([entry.id | socket.assigns.agent_log_ids], 500)

    socket =
      Enum.reduce(dropped, stream_insert(socket, :agent_logs, entry, at: 0), fn id, acc ->
        stream_delete_by_dom_id(acc, :agent_logs, "agent-log-#{id}")
      end)

    {:noreply, assign(socket, :agent_log_ids, kept)}
  end

  # RLY-112: recompute every card's health and re-render ONLY the cards whose state
  # actually changed. list_cards/1 is the same read mount does; it is also how the
  # heartbeat column reaches this socket, since heartbeats deliberately never broadcast.
  def handle_info(:health_tick, socket) do
    cards = Cards.list_cards(socket.assigns.board)
    fresh = health_by_card(cards, socket.assigns.board.stages)
    previous = socket.assigns.health_by_card

    changed = Enum.filter(cards, &(health_state(fresh, &1.id) != health_state(previous, &1.id)))

    socket =
      socket
      |> assign(:health_by_card, fresh)
      |> assign_run_diagnostics(socket.assigns.board, socket.assigns.run_summaries)

    {:noreply,
     Enum.reduce(changed, socket, fn card, acc ->
       if find_stage_by_id(acc, card.stage_id) do
         stream_insert(acc, stream_name(card.stage_id), card)
       else
         acc
       end
     end)}
  end

  # RLY-112: one event per card per flush, carrying the whole batch. Entries are
  # chronological ascending, so inserting each at: 0 leaves the newest on top.
  def handle_info({:card_log_appended, card_id, entries}, socket) do
    socket =
      case socket.assigns.selected_card do
        %Card{id: ^card_id} -> Enum.reduce(entries, socket, &stream_insert(&2, :activity, &1, at: 0))
        _other -> socket
      end

    {:noreply, refresh_card_health(socket, card_id, List.last(entries))}
  end

  # `Phoenix.Ecto.SQL.Sandbox` traps exits on the request process by default (recommended for
  # browser-driven tests, so DB connections shut down cleanly instead of corrupting the sandbox
  # when a browser navigates away mid-request) — that requires a catch-all clause here so a
  # linked process exiting normally doesn't crash the LiveView.
  def handle_info({:EXIT, _pid, _reason}, socket), do: {:noreply, socket}

  defp insert_timeline_entry(socket, %Schemas.Comment{} = comment) do
    insert_note(socket, comment)
  end

  defp insert_timeline_entry(socket, %Schemas.Activity{} = activity) do
    stream_insert(socket, :activity, activity, at: 0)
  end

  defp health_by_card(cards, stages) do
    newest = Activity.newest_per_card(Enum.map(cards, & &1.id))
    ai_stage_ids = MapSet.new(for stage <- stages, stage.ai_enabled, do: stage.id)
    now = DateTime.utc_now()

    Map.new(cards, fn card ->
      entry = Map.get(newest, card.id)

      state =
        Cards.health(%{
          newest: entry,
          heartbeat_at: card.agent_heartbeat_at,
          ai_active?: Cards.active_owner_type(card) == :ai,
          ai_stage?: MapSet.member?(ai_stage_ids, card.stage_id),
          now: now
        })

      {card.id, %{state: state, entry: entry}}
    end)
  end

  defp health_state(health_by_card, card_id) do
    health_by_card |> Map.get(card_id, %{}) |> Map.get(:state, :none)
  end

  # RLY-137 — the board-face run affordance per card, rebuilt from a fresh card list
  # whenever one is on hand (mount, card_upserted, card_moved, reload_board) rather
  # than patched incrementally like health: face_summary/4 is cheap (pure map lookups
  # over already-loaded :flows / :run_summaries) and a card's stage/status/owner can
  # all move its face at once (e.g. into the queued or review states).
  defp face_runs(cards, flows, summaries) do
    Map.new(cards, fn card ->
      {card.id, Runs.face_summary(card, Cards.active_owner_type(card), flows, summaries)}
    end)
  end

  # RLY-191: the two board-level diagnostics recomputed on every :health_tick — the run-face
  # age/stall map (keyed by card_id for the template) and the stopped-work banner. Both read
  # the one diagnosis path in Relay.Runs; no re-derivation here.
  defp assign_run_diagnostics(socket, board, run_summaries) do
    now = DateTime.utc_now()
    progress = Runs.last_progress_by_run(board)
    working = Runs.working_run_ids(board, now)

    meta =
      for {card_id, s} <- run_summaries, s.status in Run.active_statuses(), into: %{} do
        progress_at = Map.get(progress, s.run_id) || s.started_at

        {card_id,
         %{progress_at: progress_at, stalled?: Runs.run_stalled?(progress_at, MapSet.member?(working, s.run_id), now)}}
      end

    socket
    |> assign(:run_face_meta, meta)
    |> assign(:stopped_work, Runs.stopped_work(board, now))
  end

  defp stopped_work_banner_style(:executor_outdated),
    do: "background:oklch(0.97 0.04 85);border:1px solid oklch(0.85 0.09 85);color:oklch(0.42 0.09 85);"

  defp stopped_work_banner_style(_reason),
    do: "background:oklch(0.97 0.03 22);border:1px solid oklch(0.88 0.07 22);color:oklch(0.48 0.13 22);"

  defp refresh_face_runs(socket, cards_by_stage) do
    cards = cards_by_stage |> Map.values() |> List.flatten()
    assign(socket, :face_runs, face_runs(cards, socket.assigns.flows, socket.assigns.run_summaries))
  end

  # RLY-204 — record that `card_id`'s run changed and arm the debounce timer once per burst.
  # `run_flush_events` counts every event in the burst (across all cards); the dirty MapSet
  # dedupes to the cards to refetch. The pending? gate arms exactly one send_after per burst,
  # mirroring Relay.Runs.Scheduler.Server.mark_dirty/1.
  defp mark_run_dirty(socket, card_id) do
    socket =
      socket
      |> assign(:dirty_run_cards, MapSet.put(socket.assigns.dirty_run_cards, card_id))
      |> assign(:run_flush_events, socket.assigns.run_flush_events + 1)

    if socket.assigns.run_flush_pending? do
      socket
    else
      Process.send_after(self(), :flush_run_changes, @run_flush_debounce_ms)
      assign(socket, :run_flush_pending?, true)
    end
  end

  # RLY-204 — refetch one dirty card: recompute its summary + face (scoped, not whole-board),
  # restream it when its stage is loaded and it is unarchived, and refresh the open drawer's
  # timeline when this is the selected card. A hard-deleted card drops out of both maps.
  defp flush_dirty_card(socket, card_id, board, flows) do
    case Cards.get_card(board, card_id) do
      %Card{} = card ->
        summary = Runs.run_summary_for_card(card)

        run_summaries =
          if summary,
            do: Map.put(socket.assigns.run_summaries, card_id, summary),
            else: Map.delete(socket.assigns.run_summaries, card_id)

        face = Runs.face_summary(card, Cards.active_owner_type(card), flows, run_summaries)

        socket =
          socket
          |> assign(:run_summaries, run_summaries)
          |> assign(:face_runs, Map.put(socket.assigns.face_runs, card_id, face))

        socket =
          if is_nil(card.archived_at) and find_stage_by_id(socket, card.stage_id) do
            stream_insert(socket, stream_name(card.stage_id), card)
          else
            socket
          end

        case socket.assigns.selected_card do
          %Card{id: ^card_id} -> assign(socket, :card_runs, Runs.list_runs_for_card(card))
          _other -> socket
        end

      nil ->
        socket
        |> assign(:run_summaries, Map.delete(socket.assigns.run_summaries, card_id))
        |> assign(:face_runs, Map.delete(socket.assigns.face_runs, card_id))
    end
  end

  # A new newest entry arrived ({:card_log_appended, …}): store it, recompute,
  # and restream the card so the strip updates in place.
  defp refresh_card_health(socket, card_id, newest_entry) do
    case Cards.get_card(socket.assigns.board, card_id) do
      nil ->
        socket

      card ->
        socket = put_card_health(socket, card, newest_entry)

        if is_nil(card.archived_at) and find_stage_by_id(socket, card.stage_id) do
          stream_insert(socket, stream_name(card.stage_id), card)
        else
          socket
        end
    end
  end

  # The card's stage or owners changed but its newest entry did not ({:card_moved, …} /
  # {:card_upserted, …}): recompute from the stored entry; the caller restreams.
  defp refresh_card_health(socket, card_id) do
    entry = socket.assigns.health_by_card |> Map.get(card_id, %{}) |> Map.get(:entry)

    case Cards.get_card(socket.assigns.board, card_id) do
      nil -> socket
      card -> put_card_health(socket, card, entry)
    end
  end

  defp put_card_health(socket, %Card{} = card, entry) do
    state =
      Cards.health(%{
        newest: entry,
        heartbeat_at: card.agent_heartbeat_at,
        ai_active?: Cards.active_owner_type(card) == :ai,
        ai_stage?: ai_stage?(socket, card.stage_id),
        now: DateTime.utc_now()
      })

    assign(socket, :health_by_card, Map.put(socket.assigns.health_by_card, card.id, %{state: state, entry: entry}))
  end

  # "Relay AI listens here" — the stage flag that gates the whole health surface
  # (2026-07-16 rejection). A stage this socket can't see gates closed.
  defp ai_stage?(socket, stage_id) do
    match?(%Stage{ai_enabled: true}, find_stage_by_id(socket, stage_id))
  end

  # Groups position-ordered stages under their category, keeping the fixed
  # category order and dropping empty categories (per spec: headers render
  # only for non-empty categories).
  defp group_stages(stages) do
    groups = stages |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.group_by(& &1.category)

    @category_order
    |> Enum.map(&{&1, Map.get(groups, &1, [])})
    |> Enum.reject(fn {_category, category_stages} -> category_stages == [] end)
  end

  # RLY-94 — the chip strip flattens category bands into one ordered stage list.
  defp flat_stages(stage_groups) do
    for {_category, stages} <- stage_groups, stage <- stages, do: stage
  end

  # Children grouped under their parent's id, each list ordered Review→Done.
  defp sublanes_by_parent(stages) do
    stages
    |> Enum.filter(&(not is_nil(&1.parent_id)))
    |> Enum.group_by(& &1.parent_id)
    |> Map.new(fn {parent_id, children} -> {parent_id, Enum.sort_by(children, &lane_order/1)} end)
  end

  # Sub-lanes should only ever be :review/:done (Schemas.Stage.validate_child_type/1
  # enforces this on write), but a stray/legacy row must degrade rather than 500 the
  # whole board — sort it last rather than raising.
  defp lane_order(%Stage{type: :review}), do: 0
  defp lane_order(%Stage{type: :done}), do: 1
  defp lane_order(%Stage{}), do: 2

  defp lane_label(:review), do: "Review"
  defp lane_label(:done), do: "Done"
  defp lane_label(type), do: type |> Atom.to_string() |> String.capitalize()

  # The owner dot's color: derived from ai_enabled (RLY-46 — the type/ai_enabled model
  # replaces the owner column; the stage_type_icon redesign lands in its own task).
  defp stage_owner(%Stage{ai_enabled: true}), do: :ai
  defp stage_owner(%Stage{}), do: :human

  # Streams can't be counted, so lane counts live in their own assign,
  # recomputed from the grouped cards (mount, moves) and bumped on create.
  defp stage_counts(stages, cards_by_stage) do
    Map.new(stages, fn stage -> {stage.id, length(Map.get(cards_by_stage, stage.id, []))} end)
  end

  # RLY-48 board derivations: the terminal stage id (for the Done rendering) and the per-card
  # needs_input question previews. Cheap; recomputed alongside the stage counts.
  defp assign_board_derivations(socket, board) do
    socket
    |> assign(:terminal_stage_id, terminal_stage_id(board.stages))
    |> assign(:needs_input_questions, Cards.needs_input_questions(board))
  end

  defp terminal_stage_id(stages) do
    case Boards.terminal_stage(stages) do
      %Stage{id: id} -> id
      nil -> nil
    end
  end

  # MMF 12c + RLY-111 — a stage renders as the mockup's 44px strip when: the user
  # re-collapsed it this session (stage_force_closed, RLY-111); else NOT when they
  # force-opened it; else when it is collapsed-by-default (RLY-111, count-independent);
  # else when it is empty across its main lane AND all sub-lanes (MMF 12c). An explicit
  # session gesture beats the board-wide setting; the setting beats the count.
  defp stage_collapsed?(%Stage{} = stage, stage_counts, sublanes_by_parent, force_open, stage_force_closed) do
    cond do
      MapSet.member?(stage_force_closed, stage.id) -> true
      MapSet.member?(force_open, stage.id) -> false
      stage.collapsed_by_default -> true
      true -> total_count(stage, stage_counts, sublanes_by_parent) == 0
    end
  end

  defp total_count(stage, stage_counts, sublanes_by_parent) do
    sublanes_by_parent
    |> Map.get(stage.id, [])
    |> Enum.reduce(Map.fetch!(stage_counts, stage.id), fn sub, acc ->
      acc + Map.fetch!(stage_counts, sub.id)
    end)
  end

  # RLY-1 items 2 & 3 — effective per-session collapse state for a main lane or a
  # sub-lane: force_closed wins (user-collapsed), then force_open (user-expanded an
  # empty lane), then the auto default — a sub-lane auto-collapses to its strip when
  # empty (MMF 12c); a main "In progress" lane never auto-collapses.
  defp lane_collapsed?(id, lane, stage_counts, force_open, force_closed) do
    cond do
      MapSet.member?(force_closed, id) -> true
      MapSet.member?(force_open, id) -> false
      lane == :main -> false
      true -> Map.fetch!(stage_counts, id) == 0
    end
  end

  # Only stages of the user's own board are addressable from events.
  # Every action taken in this LiveView is attributed to the signed-in
  # human; the :agent default on the Cards mutators is the API's (MMF 09).
  defp current_actor(socket), do: {:user, socket.assigns.current_scope.user.id}

  # RE247 — the header badge AND the dialog's rows from ONE Runs.stalled_cards/1 call, so the
  # count can never claim a different set than the list names (it replaces RLY-228's
  # count-only assign). Recomputed on mount, on every coalesced run-event flush, when the
  # dialog opens, and after each per-row restart.
  defp assign_stalled(socket) do
    stalled = Runs.stalled_cards(socket.assigns.board)

    socket
    |> assign(:stalled_cards, stalled)
    |> assign(:stalled_count, length(stalled))
  end

  # The list is refreshed either way, so a refused restart still re-renders honest rows.
  # Emptying the list closes the dialog: the header control that opened it is about to
  # disappear, and an empty modal would strand the user behind a backdrop.
  defp after_restart_one(socket, ref, {:ok, _run}) do
    socket =
      socket
      |> assign_stalled()
      |> assign(:stalled_error, nil)
      |> put_flash(:info, "Restarted #{ref}.")

    if socket.assigns.stalled_cards == [], do: assign(socket, :stalled_open, false), else: socket
  end

  # The dialog deliberately stays open on a refusal (RE247 review), so the toast alone is
  # not enough feedback — it paints under the modal's 40% overlay (z-50 vs the modal's
  # z-999), and the natural next click lands on the backdrop and dismisses the dialog
  # instead of the flash. `:stalled_error` renders the same sentence inside `.modal-box`,
  # where the refusal is actually visible; the flash is kept too for parity with the
  # success path and any non-modal (embed) surface.
  defp after_restart_one(socket, _ref, {:error, reason}) do
    message = Runs.retry_refusal_message(reason)

    socket
    |> assign_stalled()
    |> assign(:stalled_error, message)
    |> put_flash(:error, message)
  end

  # RLY-94 — the card-tap bridge payload. `kind` tells the shell which native
  # action bar to render without a fetch: "in_review" at a review gate,
  # "needs_input" when blocked on a human, "failed" for a dead run (RLY-179),
  # nil otherwise. The first two mirror the push deep-link convention
  # (Relay.Push.copy/1); "failed" has no push counterpart, since
  # card_status_changed/3 never pushes for :failed. An unknown ref is a silent
  # no-op, like move_card.
  #
  # RLY-234 — also carries `cards`: the tapped card's stage column, ordered
  # exactly as the board renders it (Cards.stage_column/2), each entry with
  # its own `kind`. This `cards` key is the wire contract the native shell
  # reads (board_screen.dart navContextForTap → payload['cards']); keep the
  # two in lockstep. Native swipe (CardScreen) computes prev/next from this
  # list locally, with no per-swipe network round trip.
  defp push_card_tap(socket, ref) do
    board = socket.assigns.board

    case Cards.get_card_by_ref(board, ref) do
      %Card{} = card ->
        push_event(socket, "card-tap", %{
          ref: ref,
          board: board.slug,
          kind: card_tap_kind(card),
          cards: tapped_column(board, card)
        })

      nil ->
        socket
    end
  end

  defp tapped_column(board, %Card{stage_id: stage_id}) do
    board
    |> Cards.stage_column(stage_id)
    |> Enum.map(&%{ref: Cards.ref(board, &1), kind: card_tap_kind(&1)})
  end

  defp card_tap_kind(%Card{status: :in_review}), do: "in_review"
  defp card_tap_kind(%Card{status: :needs_input}), do: "needs_input"
  defp card_tap_kind(%Card{status: :failed}), do: "failed"
  defp card_tap_kind(%Card{}), do: nil

  defp find_stage(socket, stage_id) do
    find_stage_by_id(socket, String.to_integer(stage_id))
  end

  defp find_stage_by_id(socket, stage_id) do
    Enum.find(socket.assigns.board.stages, &(&1.id == stage_id))
  end

  # Drawer move targets: every stage on this board except the card's
  # current one, in position order. Sub-lanes are ordinary move_card
  # targets (per plan Architecture: "no move changes"), but must show a
  # human label ("Code · Review") rather than the composite internal
  # Stage.name ("Code:Review") built by Boards.enable_lane/2 — the same
  # leak lane_label/1 already guards against on the board itself.
  defp move_targets(board, %Card{stage_id: stage_id}) do
    stages_by_id = Map.new(board.stages, &{&1.id, &1})

    board.stages
    |> Enum.reject(&(&1.id == stage_id))
    |> Enum.map(&%{id: &1.id, name: move_target_name(&1, stages_by_id)})
  end

  defp move_target_name(%Stage{parent_id: nil} = stage, _stages_by_id), do: stage.name

  defp move_target_name(%Stage{parent_id: parent_id} = stage, stages_by_id) do
    parent = Map.fetch!(stages_by_id, parent_id)
    "#{parent.name} · #{lane_label(stage.type)}"
  end

  # The drawer header chip and "Stage" rail label render whatever stage
  # is selected, including a sub-lane child — sanitize it the same way
  # move_target_name/2 already does for the move menu, so the composite
  # internal Stage.name ("Code:Review") never reaches either spot.
  defp drawer_stage_name(%Stage{} = stage, stages) do
    move_target_name(stage, Map.new(stages, &{&1.id, &1}))
  end

  defp resolve_stage(socket, stage_id) do
    case parse_int(stage_id) do
      nil -> nil
      id -> find_stage_by_id(socket, id)
    end
  end

  # The drop index from the DnD hook; the drawer omits it, meaning
  # "append to the bottom" — the target's current count clamps to the
  # last slot inside Cards.move_card/3.
  defp resolve_index(%{"index" => index}, _socket, _stage), do: parse_int(index)
  defp resolve_index(_params, socket, stage), do: Map.fetch!(socket.assigns.stage_counts, stage.id)

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  # RE260 — a merged (Hide tasks) column names an ACTIVITY, not a task, and
  # StoryMap.resolve_placement/2 is total: passing the decoded `%{story_activity_id: _}` straight
  # through would write `story_task_id: nil`. So a user who hides tasks and drags a card one lane
  # down to change its RELEASE would silently lose the card's task — data loss from a gesture
  # that looks purely vertical. The artboard does exactly that (`onDropCell(e, (col.merged ||
  # col.noTask) ? null : …)`, line ~530) and gets away with it because the mock persists nothing.
  #
  # Rule instead: keep the existing task when it belongs to the activity being dropped on, and
  # clear it only when the card genuinely changes activities. A `nt:` (`— No task yet`) drop is a
  # different key and still clears — that is the point of that column.
  defp merged_drop_attrs(placement, column, card, tasks) do
    if StoryMapGrid.merged_column?(column) and keeps_task?(card, placement, tasks) do
      placement |> Map.delete(:story_activity_id) |> Map.put(:story_task_id, card.story_task_id)
    else
      placement
    end
  end

  defp keeps_task?(%Card{story_task_id: nil}, _placement, _tasks), do: false

  defp keeps_task?(%Card{story_task_id: task_id}, %{story_activity_id: activity_id}, tasks) do
    Enum.any?(tasks, &(&1.id == task_id and &1.story_activity_id == activity_id))
  end

  defp resolve_actor(%{"actor_type" => "agent"}), do: :agent

  defp resolve_actor(%{"actor_type" => "user", "user_id" => user_id}) do
    case parse_int(user_id) do
      nil -> nil
      id -> {:user, id}
    end
  end

  defp resolve_actor(_params), do: nil

  defp member_user_id?(socket, id) do
    Enum.any?(socket.assigns.members, &(&1.user_id == id))
  end

  defp apply_owner_change(socket, {:ok, %Card{} = card}), do: {:noreply, refresh_card(socket, card)}
  defp apply_owner_change(socket, {:error, _changeset}), do: {:noreply, socket}

  # A persisted baton change: sync the drawer assigns and re-stream the
  # card so the board card re-renders its colour/badge. Also recomputes
  # the needs-input panel's question from the fresh timeline (MMF 14).
  defp refresh_card(socket, %Card{} = card) do
    activity = Activity.list_activity(card, limit: @activity_render_limit)

    socket
    |> assign(:selected_card, card)
    |> assign(:body_loading?, false)
    |> assign_question(card, activity)
    |> assign(:answer_step, 0)
    |> assign(:answer_values, %{})
    |> assign(:answer_form, empty_answer_form())
    |> assign_review(card)
    # the card may have parked/resumed a run since the last refresh
    |> assign(:card_runs, Runs.list_runs_for_card(card))
    |> stream_notes(Activity.list_conversation(card))
    |> stream(:activity, activity, reset: true)
    |> stream_insert(stream_name(card.stage_id), card)
  end

  # Approve/reject moved the card: re-stream the source and target stage
  # columns (and counts) exactly like any move, then refresh the drawer to
  # the updated card — review panel and timeline included.
  defp refresh_after_review(socket, %Card{} = before, %Card{} = updated) do
    socket
    |> apply_move(before.stage_id, updated)
    |> refresh_card(updated)
  end

  # RLY-115 — a primary review decision (Approve / Request changes) dispatches the
  # card, so the drawer's job is done: keep the column re-stream + counts
  # (apply_move/3) but skip the drawer refresh, and patch back to the board URL —
  # the patch's handle_params clears selected_card, which closes the drawer.
  # Archive's precedent, minus the flash: the card's new column placement is the
  # confirmation. Card mode (/cards/:ref) keeps refresh-in-place — the native
  # shell owns dismissal (RLY-87) and there is no board behind the drawer.
  defp after_review_decision(%{assigns: %{live_action: :card}} = socket, %Card{} = before, %Card{} = updated) do
    refresh_after_review(socket, before, updated)
  end

  defp after_review_decision(socket, %Card{} = before, %Card{} = updated) do
    socket
    |> apply_move(before.stage_id, updated)
    |> close_drawer_after_action()
  end

  defp close_drawer_after_action(socket) do
    push_patch(socket, to: board_path(socket.assigns))
  end

  # RLY-115 — an answered block resumes the card, so the drawer's job is done:
  # re-stream the card tile (the amber badge flips off synchronously, as
  # refresh_card/2 does today), refresh the board-level question previews, then
  # patch back to the board URL. Card mode keeps refresh-in-place (RLY-87).
  defp after_answer(%{assigns: %{live_action: :card}} = socket, %Card{} = updated) do
    refresh_card(socket, updated)
  end

  defp after_answer(socket, %Card{} = updated) do
    socket
    |> stream_insert(stream_name(updated.stage_id), updated)
    |> assign(:needs_input_questions, Cards.needs_input_questions(socket.assigns.board))
    |> close_drawer_after_action()
  end

  # MMF 15 — the drawer's review-panel assigns. Recomputed on every drawer
  # refresh so the panel appears/disappears as the status changes and the
  # note sub-panel collapses after a transition.
  defp assign_review(socket, %Card{status: :in_review} = card) do
    assign(socket,
      review_gate: review_gate_info(socket, card),
      reject_open: false,
      reject_form: empty_reject_form(),
      reject_error: nil
    )
  end

  defp assign_review(socket, _card) do
    assign(socket,
      review_gate: nil,
      reject_open: false,
      reject_form: empty_reject_form(),
      reject_error: nil
    )
  end

  # Gate info for the review panel, or nil unless the card sits in a review-type stage —
  # mirroring Cards.approve/reject's :not_in_review guard so Approve/Request changes only
  # render where the transition can succeed.
  defp review_gate_info(socket, %Card{} = card) do
    stage = find_stage_by_id(socket, card.stage_id)

    if stage.type == :review do
      target = Cards.reject_target(card)

      %{
        approve_label: approve_label(card),
        reject_target_name: target && Boards.stage_display_name(target),
        can_reject: target != nil
      }
    end
  end

  # Derived from the domain target (Cards.approve_target/1) so the label can never drift from the
  # actual move. stage_display_name/1 renders a Done substage as "<Parent> · Done" (not the
  # internal composite "<Parent>:Done"). nil target = complete in place at the terminal stage.
  defp approve_label(card) do
    case Cards.approve_target(card) do
      nil -> "Approve → Done"
      %Stage{} = target -> "Approve → #{Boards.stage_display_name(target)}"
    end
  end

  defp empty_reject_form, do: to_form(%{"note" => ""}, as: :reject)

  # The move already persisted; stream items can't be reordered in
  # place, so refetch and reset the source and target stage streams,
  # refresh the lane counts, and keep the drawer in sync when the moved
  # card is the selected one.
  # RLY-217 — the stranding pre-check: a live run out of its work lane prompts instead of
  # moving (prompt_stranded_move/6); otherwise the move proceeds as before.
  defp move_or_prompt(socket, ref, %Card{} = card, %Stage{} = stage, index) do
    case Cards.stranded_run(card, stage) do
      nil -> apply_ordinary_move(socket, card, stage, index)
      %Run{} = run -> {:noreply, prompt_stranded_move(socket, ref, card, stage, index, run)}
    end
  end

  defp apply_ordinary_move(socket, %Card{} = card, %Stage{} = stage, index) do
    case Cards.move_card(card, stage, index, current_actor(socket)) do
      {:ok, moved} ->
        {:noreply, socket |> apply_move(card.stage_id, moved) |> maybe_warn_over_wip(stage, card.stage_id)}

      _error ->
        {:noreply, socket}
    end
  end

  # RLY-217 — a drop/menu-move that would strand a live run: do NOT move. Stash the intent so
  # the modal (rendered from @pending_move) can name the exact consequence, and restream the
  # source + destination lanes so the optimistically-dragged card visibly returns to origin.
  defp prompt_stranded_move(socket, ref, %Card{} = card, %Stage{} = stage, index, %Run{} = run) do
    pending = %{
      ref: ref,
      source_stage_id: card.stage_id,
      target_stage_id: stage.id,
      target_stage_name: stage.name,
      index: index,
      run_id: run.id,
      status: run.status,
      node: run.current_node,
      flow_key: run.flow_key
    }

    socket
    |> assign(:pending_move, pending)
    |> restream_lanes([card.stage_id, stage.id])
  end

  defp apply_move(socket, source_stage_id, %Card{} = moved) do
    cards_by_stage = socket.assigns.board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket
    |> adjust_done_revealed(source_stage_id, moved.stage_id, cards_by_stage)
    |> restream_stage(source_stage_id, cards_by_stage)
    |> restream_stage(moved.stage_id, cards_by_stage)
    |> assign(:stage_counts, stage_counts(socket.assigns.board.stages, cards_by_stage))
    |> refresh_selected_after_move(moved)
  end

  # RLY-53 — keep the Done reveal count consistent as cards cross the terminal
  # boundary. A card entering Done is revealed on top without hiding a shown one
  # (bump by 1, capped at the new count); a card leaving clamps the window to
  # what remains. Reorders within Done, and moves that never touch Done, leave
  # done_revealed untouched. Runs before the restream, which reads done_revealed.
  defp adjust_done_revealed(socket, source_stage_id, target_stage_id, cards_by_stage) do
    terminal_id = socket.assigns.terminal_stage_id
    done_count = length(Map.get(cards_by_stage, terminal_id, []))

    cond do
      is_nil(terminal_id) ->
        socket

      target_stage_id == terminal_id and source_stage_id != terminal_id ->
        update(socket, :done_revealed, &min(&1 + 1, done_count))

      source_stage_id == terminal_id and target_stage_id != terminal_id ->
        update(socket, :done_revealed, &min(&1, done_count))

      true ->
        socket
    end
  end

  # RLY-53 — the single windowing gate: the terminal Done column streams only
  # its newest @done_revealed cards (via Cards.list_stage_cards/2); every other
  # stage streams its full list from cards_by_stage. Route every (re)stream of a
  # stage through here so the Done cap holds identically on mount, reveal,
  # reload, move, and realtime restream.
  defp stream_stage(socket, stage_id, cards_by_stage, opts \\ []) do
    stream(socket, stream_name(stage_id), stage_window(socket, stage_id, cards_by_stage), opts)
  end

  defp stage_window(socket, stage_id, cards_by_stage) do
    if stage_id == socket.assigns.terminal_stage_id do
      terminal_stage = find_stage_by_id(socket, stage_id)
      Cards.list_stage_cards(terminal_stage, socket.assigns.done_revealed)
    else
      Map.get(cards_by_stage, stage_id, [])
    end
  end

  # RLY-53 — the terminal Done column is a bounded window, so an upsert there
  # re-derives the window (a blind stream_insert could surface a card meant to
  # stay behind "Show more"). Every other stage upserts in place by DOM id.
  defp upsert_card_stream(socket, %Card{stage_id: stage_id} = card, cards_by_stage) do
    if stage_id == socket.assigns.terminal_stage_id do
      stream_stage(socket, stage_id, cards_by_stage, reset: true)
    else
      stream_insert(socket, stream_name(stage_id), card)
    end
  end

  defp restream_stage(socket, stage_id, cards_by_stage) do
    stream_stage(socket, stage_id, cards_by_stage, reset: true)
  end

  # RLY-145 — refetch all board cards once and stream-reset each given lane.
  # Every expand gesture routes here: items streamed while a container was
  # hidden were consumed at render time and dropped, so revealing a lane must
  # re-send its cards. Goes through stream_stage/4 (via restream_stage/3) so
  # the RLY-53 Done window still holds.
  defp restream_lanes(socket, stage_ids) do
    cards_by_stage = socket.assigns.board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)
    Enum.reduce(stage_ids, socket, &restream_stage(&2, &1, cards_by_stage))
  end

  defp sublane_ids(socket, stage_id) do
    socket.assigns.sublanes_by_parent |> Map.get(stage_id, []) |> Enum.map(& &1.id)
  end

  # RLY-4 — a card was archived (locally or via broadcast): drop it from its
  # column, recompute every stage count from the DB (list_cards now excludes
  # archived, so counts fall for free — idempotent on the acting session's own
  # echo), and refresh the archived-count badge.
  defp apply_archive(socket, %Card{} = card) do
    cards_by_stage = socket.assigns.board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket
    |> stream_delete(stream_name(card.stage_id), card)
    |> assign(:stage_counts, stage_counts(socket.assigns.board.stages, cards_by_stage))
    |> assign_archived_count()
  end

  # Close the drawer when the just-archived card is the one open here.
  defp close_drawer_if_selected(socket, %Card{id: id}) do
    case socket.assigns.selected_card do
      %Card{id: ^id} -> push_patch(socket, to: board_path(socket.assigns))
      _other -> socket
    end
  end

  defp assign_archived_count(socket) do
    assign(socket, :archived_count, Cards.count_archived_cards(socket.assigns.board))
  end

  # MMF 11 / RLY-35 — soft enforcement, now sub-lane-aware. A move that lands
  # in a limited main stage OR any of its sub-lanes still succeeds; the acting
  # session gets a non-blocking flash when the governing main stage's total
  # (main + sub-lanes, from the freshly recomputed @stage_counts) is over
  # limit. A move whose source and target share the same governing main stage
  # (a reorder, or shuffling between a stage and its own sub-lanes) never
  # warns, and only this handler flashes — broadcast-applied moves stay silent.
  defp maybe_warn_over_wip(socket, %Stage{} = target, from_stage_id) do
    case governing_main_stage(socket, target) do
      %Stage{wip_limit: limit} = gate when is_integer(limit) ->
        used = wip_used(socket, gate)

        if governing_main_id(socket, from_stage_id) != gate.id and used > limit do
          put_flash(socket, :error, "#{gate.name} is over its WIP limit — #{used}/#{limit}")
        else
          socket
        end

      _ ->
        socket
    end
  end

  # The main-lane stage a WIP limit is charged against: the stage itself when
  # it's a main lane, else its parent. A move into any sub-lane counts here.
  defp governing_main_stage(_socket, %Stage{parent_id: nil} = stage), do: stage
  defp governing_main_stage(socket, %Stage{parent_id: parent_id}), do: find_stage_by_id(socket, parent_id)

  # The id of the governing main stage for an arbitrary stage id (source of a move).
  defp governing_main_id(socket, stage_id) do
    case find_stage_by_id(socket, stage_id) do
      %Stage{} = stage -> governing_main_stage(socket, stage).id
      _ -> nil
    end
  end

  # Effective WIP count for a main stage: its own cards plus every sub-lane's,
  # read from the freshly recomputed @stage_counts.
  defp wip_used(socket, %Stage{id: id}) do
    counts = socket.assigns.stage_counts

    socket.assigns.sublanes_by_parent
    |> Map.get(id, [])
    |> Enum.reduce(Map.fetch!(counts, id), fn sub, acc -> acc + Map.fetch!(counts, sub.id) end)
  end

  defp refresh_selected_after_move(socket, %Card{} = moved) do
    moved_id = moved.id

    case socket.assigns.selected_card do
      %Card{id: ^moved_id} ->
        socket
        |> assign(:selected_card, moved)
        |> assign(:body_loading?, false)
        |> assign(:selected_stage, find_stage_by_id(socket, moved.stage_id))
        |> assign_review(moved)
        |> stream_notes(Activity.list_conversation(moved))
        |> stream(:activity, Activity.list_activity(moved, limit: @activity_render_limit), reset: true)

      _ ->
        socket
    end
  end

  # A remotely upserted card that is open in this session's drawer: sync
  # the drawer assigns (selected card, status form, timeline) through the
  # same refresh_card/2 path local drawer actions use.
  defp maybe_refresh_drawer(socket, %Card{id: id} = card) do
    case socket.assigns.selected_card do
      %Card{id: ^id} -> refresh_card(socket, card)
      _other -> socket
    end
  end

  # `:card_upserted` (fired inside Cards.set_status/3, before Cards.request_input/3 logs the
  # question) can beat the `:needs_input` Activity entry to this session, so refresh_card/2's
  # question ends up blank until this later `:timeline_appended` for that entry lands — recompute
  # it here too rather than waiting on the next unrelated card_upserted to paper over it.
  # `entry` already carries the full `:needs_input` meta (question/questions) that
  # latest_question/2 and latest_questions/2 scan for, so it stands in for a freshly-fetched
  # activity list without the round trip.
  defp refresh_needs_input_question(socket, %Card{} = card, %Schemas.Activity{type: :needs_input} = entry) do
    assign_question(socket, card, [entry])
  end

  defp refresh_needs_input_question(socket, %Card{}, _entry), do: socket

  # Shared by refresh_card/2 and refresh_needs_input_question/3: recompute the
  # needs-input panel's current question/step options from a freshly-fetched
  # activity timeline.
  defp assign_question(socket, %Card{} = card, activity) do
    socket
    |> assign(:question, latest_question(card, activity))
    |> assign(:answer_questions, latest_questions(card, activity))
  end

  # stages_changed (or an event for a stage this socket doesn't know yet):
  # refetch the board and rebuild every stage-derived assign and stream,
  # exactly like mount does. Streams reset from the DB, so this is
  # idempotent and safe to run on the acting session's own echo too.
  defp reload_board(socket) do
    board = Boards.get_board!(socket.assigns.current_scope.user, socket.assigns.board.slug)
    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket =
      socket
      |> assign(:board, board)
      |> assign(:read_only?, Board.archived?(board))
      |> assign(:stage_groups, group_stages(board.stages))
      |> assign(:stage_counts, stage_counts(board.stages, cards_by_stage))
      |> assign(:sublanes_by_parent, sublanes_by_parent(board.stages))
      |> assign_board_derivations(board)
      |> assign_archived_count()
      |> refresh_face_runs(cards_by_stage)

    board.stages
    |> Enum.reduce(socket, fn stage, acc ->
      stream_stage(acc, stage.id, cards_by_stage, reset: true)
    end)
    |> refresh_selected_stage()
    |> refresh_story_map()
  end

  # RE264 — refetch-and-reassign, the same coarse contract PublicBoardLive uses: cards move
  # between cells and the tray live, and RE263's new activities appear without a reload. It
  # no-ops unless this socket is actually rendering the map.
  defp refresh_story_map(%{assigns: %{live_action: :story_map}} = socket) do
    board = socket.assigns.board

    socket
    |> assign(:story_activities, StoryMap.list_activities(board))
    |> assign(:story_tasks, StoryMap.list_tasks(board))
    |> assign(:releases, StoryMap.list_releases(board))
    |> assign(:story_map_cards, Cards.list_cards(board))
  end

  defp refresh_story_map(socket), do: socket

  # RE257 — one place that joins everything the map's realtime surfaces need: the roster, the
  # cursor stream and the shared view.
  defp join_story_map_presence(board, user) do
    Presence.track_viewer(self(), board.id, user)
    Presence.subscribe(board.id)
    StoryMap.subscribe_view(board.id)
    :ok
  end

  defp open_story_map_draft(socket, draft) do
    socket
    |> assign(:story_map_draft, draft)
    |> assign(:story_map_draft_name, "")
    # RE261 — mutual exclusion with an open rename, the other direction of the same rule
    # open_story_map_edit/3 enforces.
    |> assign(:story_map_edit, nil)
    |> assign(:story_map_edit_name, "")
    |> show_tasks_for_draft(draft)
  end

  # RE260 — a task draft is a NEW TASK COLUMN, and there is nowhere to render one while the
  # activity is merged. RE259 adds the other two ways it can be invisible: collapsed, or
  # focused away. The user asked to add a task, so showing that activity is the coherent
  # response (the artboard's `addTask`, line ~617) — otherwise `＋ Add task` opens an input
  # they cannot see. The other two draft shapes (activity, release) are unaffected.
  #
  # RE257 — through the shared view, NOT a local assign: these are shared board-wide now, and
  # an optimistic assign here would make this a SECOND writer of one piece of state. This
  # socket re-renders from the write's own broadcast like every other viewer. ONE
  # `merge_view/2` so the three keys land together.
  defp show_tasks_for_draft(socket, {:task, activity_id}) do
    changes = %{
      "hide_tasks" => false,
      "collapsed" => List.delete(socket.assigns.story_map_collapsed, activity_id),
      "focus" => focus_after_add_task(socket.assigns.story_map_focus, activity_id)
    }

    log_view_write(StoryMap.merge_view(socket.assigns.board, changes), "hide_tasks")
    socket
  end

  defp show_tasks_for_draft(socket, _draft), do: socket

  # Focusing THIS activity already shows it; focusing another one hides it, so the focus goes.
  defp focus_after_add_task(activity_id, activity_id), do: activity_id
  defp focus_after_add_task(_focus, _activity_id), do: nil

  # RE257 — the shared view, assigned in exactly one place so mount and the broadcast cannot
  # drift. `zoom` round-trips through jsonb as a string and comes back through `parse_zoom/1`,
  # never `String.to_atom/1`; a row holding an unparseable value falls back to the shared
  # default rather than crashing the viewer.
  defp assign_story_map_view(socket, view) do
    socket
    |> assign(:story_map_tray_open, view["tray_open"])
    |> assign(:story_map_zoom, zoom_from_view(view))
    |> assign(:story_map_hide_tasks, view["hide_tasks"] == true)
    |> assign(:story_map_owner_filter, List.wrap(view["owner_filter"]))
    |> assign(:story_map_needs_filter, view["needs_input_filter"] == true)
    |> assign(:story_map_collapsed, List.wrap(view["collapsed"]))
    # Raw here on purpose: resolving it needs the activity list, and story_map_viewport/1
    # already holds that. `List.wrap/1` and `== true` keep a hand-edited jsonb row from
    # crashing a viewer, the same way zoom_from_view/1 does.
    |> assign(:story_map_focus, view["focus"])
  end

  defp zoom_from_view(view) do
    case StoryMapComponents.parse_zoom(view["zoom"]) do
      {:ok, level} -> level
      :error -> default_zoom()
    end
  end

  defp default_zoom do
    {:ok, level} = StoryMapComponents.parse_zoom(StoryMap.view_defaults()["zoom"])
    level
  end

  # A view write that fails leaves state consistent (nothing was assigned optimistically), but a
  # click that vanishes with no trace is a black hole — say so in the log.
  defp log_view_write({:ok, _view}, _key), do: :ok

  defp log_view_write({:error, reason}, key) do
    Logger.warning("story-map view write failed for #{key}: #{inspect(reason)}")
  end

  defp close_story_map_draft(socket) do
    socket
    |> assign(:story_map_draft, nil)
    |> assign(:story_map_draft_name, "")
  end

  # RE263 — commit. Everything appends: `position` is StoryMap.next_position/1 over the lists
  # this socket has already loaded (for a task, that activity's tasks only), so no call site
  # re-types `max + 1` and no extra query is issued. The create's own
  # `{:story_map_changed, board_id}` broadcast does the refetch through refresh_story_map/1 —
  # the creating tab included — so no clause here rebuilds the lists by hand.
  defp commit_story_map_draft(socket, nil, _name), do: socket
  defp commit_story_map_draft(socket, _draft, ""), do: socket

  defp commit_story_map_draft(socket, :activity, name) do
    position = StoryMap.next_position(socket.assigns.story_activities)

    after_story_map_create(
      socket,
      StoryMap.create_activity(socket.assigns.board, %{name: name, position: position})
    )
  end

  defp commit_story_map_draft(socket, :release, name) do
    position = StoryMap.next_position(socket.assigns.releases)

    after_story_map_create(
      socket,
      StoryMap.create_release(socket.assigns.board, %{name: name, position: position})
    )
  end

  defp commit_story_map_draft(socket, {:task, activity_id}, name) do
    case Enum.find(socket.assigns.story_activities, &(&1.id == activity_id)) do
      nil ->
        close_story_map_draft(socket)

      activity ->
        position =
          socket.assigns.story_tasks
          |> Enum.filter(&(&1.story_activity_id == activity_id))
          |> StoryMap.next_position()

        after_story_map_create(socket, StoryMap.create_task(activity, %{name: name, position: position}))
    end
  end

  # The draft stays open either way. On success the input has to come back EMPTY and still
  # focused, and only the client can do that — LiveView never patches a focused input's value
  # (it would clobber active typing), so the InlineNameInput hook clears it on this event.
  # Pushing on success only is what leaves the text intact on the error path.
  defp after_story_map_create(socket, {:ok, _record}) do
    socket
    |> assign(:story_map_draft_name, "")
    |> push_event("story_map_draft_cleared", %{})
  end

  defp after_story_map_create(socket, {:error, changeset}) do
    put_flash(socket, :error, Enum.join(ChangesetErrors.messages(changeset), ", "))
  end

  # The activity is resolved from @story_activities — already board-scoped by mount_board/2,
  # which gates on Boards.get_board!/2 — never by id from the database. A forged activity-id
  # from another board finds nothing and every caller is a silent no-op.
  defp find_story_activity(socket, activity_id) do
    Enum.find(socket.assigns.story_activities, &(to_string(&1.id) == activity_id))
  end

  # RE261 — the three kinds, resolved from the assigns mount_board/2 already loaded
  # board-scoped (it gates on Boards.get_board!/2). `kind` is mapped through a total function
  # rather than String.to_atom/1, so a forged kind can never mint an atom.
  defp resolve_story_map_target(socket, kind, id) do
    with kind_atom when not is_nil(kind_atom) <- story_map_kind(kind),
         %{} = record <- Enum.find(story_map_list(socket, kind_atom), &(to_string(&1.id) == to_string(id))) do
      {kind_atom, record}
    else
      _other -> nil
    end
  end

  defp story_map_kind("activity"), do: :activity
  defp story_map_kind("task"), do: :task
  defp story_map_kind("release"), do: :release
  defp story_map_kind(_other), do: nil

  defp story_map_list(socket, :activity), do: socket.assigns.story_activities
  defp story_map_list(socket, :task), do: socket.assigns.story_tasks
  defp story_map_list(socket, :release), do: socket.assigns.releases

  defp open_story_map_edit(socket, edit, name) do
    socket
    |> assign(:story_map_edit, edit)
    |> assign(:story_map_edit_name, name)
    # Mutual exclusion with the create draft. phx-click-away already handles the common case
    # (LiveView dispatches it before the clicked element's own phx-click), but clearing
    # explicitly makes it deterministic rather than ordering-dependent.
    |> assign(:story_map_draft, nil)
    |> assign(:story_map_draft_name, "")
  end

  defp close_story_map_edit(socket) do
    socket
    |> assign(:story_map_edit, nil)
    |> assign(:story_map_edit_name, "")
  end

  # The artboard's `commitEdit` (line ~590): a BLANK name cancels — the context is never
  # called. On success the rename closes; on an invalid name (over-long) it stays open with the
  # flash, exactly like the create draft, so the user can fix it rather than retype it.
  defp commit_story_map_rename(socket, nil, _name), do: socket
  defp commit_story_map_rename(socket, _edit, ""), do: close_story_map_edit(socket)

  defp commit_story_map_rename(socket, {kind, id}, name) do
    case Enum.find(story_map_list(socket, kind), &(&1.id == id)) do
      nil ->
        close_story_map_edit(socket)

      record ->
        case rename_structure(kind, record, name) do
          {:ok, _renamed} -> close_story_map_edit(socket)
          {:error, changeset} -> put_flash(socket, :error, Enum.join(ChangesetErrors.messages(changeset), ", "))
        end
    end
  end

  defp rename_structure(:activity, record, name), do: StoryMap.update_activity(record, %{name: name})
  defp rename_structure(:task, record, name), do: StoryMap.update_task(record, %{name: name})
  defp rename_structure(:release, record, name), do: StoryMap.update_release(record, %{name: name})

  defp delete_structure(:activity, record), do: StoryMap.delete_activity(record)
  defp delete_structure(:task, record), do: StoryMap.delete_task(record)
  defp delete_structure(:release, record), do: StoryMap.delete_release(record)

  # A stale :story_map_edit pointing at a just-deleted record simply matches nothing when the
  # grid re-renders, so success needs no cleanup — the same contract a stale draft has.
  defp apply_story_map_delete(socket, {:ok, _record}), do: socket
  defp apply_story_map_delete(socket, {:error, :not_empty}), do: put_flash(socket, :error, "Move its cards out first.")
  defp apply_story_map_delete(socket, {:error, _changeset}), do: socket

  # The artboard's onDropAct / onDropTask (Relay Story Map.dc.html, lines ~681-682) as one
  # total function. Every pair the matrix does not name — a release onto the backbone, a
  # backbone header onto a release — falls through to the no-op clause.
  defp apply_story_map_reorder(socket, {:activity, dragged}, {:activity, target}) do
    reorder_story_activities(socket, dragged.id, target.id)
  end

  # Dropping an activity on a TASK header targets that task's activity.
  defp apply_story_map_reorder(socket, {:activity, dragged}, {:task, target}) do
    reorder_story_activities(socket, dragged.id, target.story_activity_id)
  end

  # A task dropped on itself: the artboard's moveTask/4 does NOT no-op this (unlike an activity
  # on itself, below) — `targetTask === taskId` takes the `else` branch and always pushes the
  # dragged task to the end of its own activity's order. Handled as its own clause rather than
  # falling into the general case below: that clause appends `dragged.id` to build a list for
  # insert_before/3 to dedupe, but insert_before/3 short-circuits to a verbatim return when
  # `id == target_id`, so the append would survive as a genuine duplicate id and renumber/3
  # would assign it two positions, leaving a gap in the final numbering.
  defp apply_story_map_reorder(socket, {:task, %{id: id} = dragged}, {:task, %{id: id}}) do
    ids = Enum.reject(story_map_task_ids(socket, dragged.story_activity_id), &(&1 == id)) ++ [id]

    _ = StoryMap.move_task(dragged, dragged.story_activity_id, ids)
    socket
  end

  defp apply_story_map_reorder(socket, {:task, dragged}, {:task, target}) do
    # The target activity's task ids WITH the dragged one appended, so insert_before/3's own
    # "remove every copy of `id` first" makes "already in this activity" and "arriving from
    # another" the same list. `dragged.id != target.id` here — the self-drop clause above
    # handles that case, where this append would instead create a genuine duplicate.
    ids =
      StoryMap.insert_before(
        story_map_task_ids(socket, target.story_activity_id) ++ [dragged.id],
        dragged.id,
        target.id
      )

    _ = StoryMap.move_task(dragged, target.story_activity_id, ids)
    socket
  end

  # The artboard's `moveTask(s, task, targetAct, null)`: dropped on an activity header, the task
  # goes to the END of that activity.
  defp apply_story_map_reorder(socket, {:task, dragged}, {:activity, target}) do
    ids = Enum.reject(story_map_task_ids(socket, target.id), &(&1 == dragged.id)) ++ [dragged.id]

    _ = StoryMap.move_task(dragged, target.id, ids)
    socket
  end

  defp apply_story_map_reorder(socket, {:release, dragged}, {:release, target}) do
    ids = StoryMap.insert_before(Enum.map(socket.assigns.releases, & &1.id), dragged.id, target.id)

    _ = StoryMap.reorder_releases(socket.assigns.board, ids)
    socket
  end

  defp apply_story_map_reorder(socket, _dragged, _target), do: socket

  defp reorder_story_activities(socket, dragged_id, target_activity_id) do
    ids =
      StoryMap.insert_before(
        Enum.map(socket.assigns.story_activities, & &1.id),
        dragged_id,
        target_activity_id
      )

    _ = StoryMap.reorder_activities(socket.assigns.board, ids)
    socket
  end

  # `@story_tasks` is already ordered by (activity, position), so this is that activity's task
  # order as the user sees it.
  defp story_map_task_ids(socket, activity_id) do
    socket.assigns.story_tasks
    |> Enum.filter(&(&1.story_activity_id == activity_id))
    |> Enum.map(& &1.id)
  end

  # After a stage reload, re-derive the open drawer's stage from the new
  # board (disable_lane refuses to remove a non-empty lane, so the
  # selected card's stage always still exists).
  defp refresh_selected_stage(socket) do
    case socket.assigns.selected_card do
      %Card{} = card ->
        socket
        |> assign(:selected_stage, find_stage_by_id(socket, card.stage_id))
        |> assign(:body_loading?, false)

      _other ->
        socket
    end
  end

  # The drawer is URL-driven: ?card=<ref> selects a card; no param — or a
  # ref that doesn't resolve on this user's board (unknown, malformed, or
  # another board's card) — means no drawer. Authorization is the board
  # scoping inside Cards.get_card_light_by_ref/2.
  #
  # RLY-68 optimistic open: paint from the light card immediately, then
  # (when connected) fetch the heavy body/timeline/conversation async.
  defp assign_selected_card(socket, ref) do
    card = if ref, do: Cards.get_card_light_by_ref(socket.assigns.board, ref)

    case card do
      %Card{} = card ->
        socket =
          socket
          |> assign(:selected_card, card)
          |> assign(:selected_stage, find_stage_by_id(socket, card.stage_id))
          |> assign_stage_neighbors(card)
          |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))
          |> assign(:editing_title, false)
          |> assign(:editing_tag, false)
          |> assign(:tag_form, nil)
          |> assign(:tag_suggestions, [])
          |> assign(:editing_description, false)
          |> assign(:description_form, nil)
          |> assign(:editing_acceptance_criteria, false)
          |> assign(:expanded_acceptance_criteria?, false)
          |> assign(:acceptance_criteria_form, nil)
          |> assign(:editing_spec, false)
          |> assign(:editing_plan, false)
          |> assign(:expanded_spec?, false)
          |> assign(:expanded_plan?, false)
          |> assign(:spec_form, nil)
          |> assign(:plan_form, nil)
          |> assign(:comment_form, empty_comment_form())
          |> assign(:answer_form, empty_answer_form())
          |> assign(:body_loading?, true)
          |> assign(:question, nil)
          |> assign(:answer_questions, nil)
          |> assign(:answer_step, 0)
          |> assign(:answer_values, %{})
          |> assign(:review_gate, nil)
          |> assign(:reject_open, false)
          |> assign(:reject_form, empty_reject_form())
          |> assign(:reject_error, nil)
          |> assign(:card_runs, [])
          |> assign(:drawer_tab, :detail)
          |> stream_notes([])
          |> stream(:activity, [], reset: true)

        maybe_start_body_load(socket, card, ref, connected?(socket))

      nil ->
        socket
        |> assign(
          selected_card: nil,
          selected_stage: nil,
          prev_ref: nil,
          next_ref: nil,
          title_form: nil,
          editing_title: false,
          editing_tag: false,
          tag_form: nil,
          tag_suggestions: [],
          editing_description: false,
          description_form: nil,
          editing_acceptance_criteria: false,
          expanded_acceptance_criteria?: false,
          acceptance_criteria_form: nil,
          editing_spec: false,
          editing_plan: false,
          expanded_spec?: false,
          expanded_plan?: false,
          spec_form: nil,
          plan_form: nil,
          comment_form: nil,
          question: nil,
          answer_questions: nil,
          answer_step: 0,
          answer_values: %{},
          answer_form: nil,
          review_gate: nil,
          reject_open: false,
          reject_form: nil,
          reject_error: nil,
          body_loading?: false
        )
        |> stream_notes([])
        |> stream(:activity, [], reset: true)
    end
  end

  # RLY-227 — the refs the drawer's prev/next chevrons + swipe navigate to, from
  # the card's own stage column (server is the single source of order and of the
  # stop-at-ends rule). Requires board.stages, which @board always carries.
  defp assign_stage_neighbors(socket, %Card{} = card) do
    %{prev: prev, next: next} = Cards.stage_neighbors(socket.assigns.board, card)
    assign(socket, prev_ref: prev, next_ref: next)
  end

  defp navigate_neighbor(socket, nil), do: socket

  # card_path/2, not a hardcoded kanban URL: patching a :story_map socket onto the nil-action
  # route does not remount, so it would stay tracked in Relay.Presence as a ghost avatar.
  defp navigate_neighbor(socket, ref) do
    push_patch(socket, to: card_path(socket.assigns, ref))
  end

  # Kick off the async heavy-body fetch when the socket is connected. On a
  # dead render (cold deep-link / refresh) there is no async — the skeleton
  # renders and the reconnect's handle_params performs the fill. The result
  # carries card_id so handle_async can drop a stale fill.
  defp maybe_start_body_load(socket, _card, _ref, false), do: socket

  defp maybe_start_body_load(socket, %Card{id: card_id}, ref, true) do
    board = socket.assigns.board

    start_async(socket, :load_card_body, fn ->
      full = Cards.get_card_by_ref(board, ref)

      %{
        card_id: card_id,
        card: full,
        activity: Activity.list_activity(full, limit: @activity_render_limit),
        conversation: Activity.list_conversation(full)
      }
    end)
  end

  # Streams are keyed per stage so each column gets its own
  # phx-update="stream" container. Stage ids come from this user's board
  # rows (a small, trusted set), not from user input, so building one atom
  # per stage is safe.
  # sobelow_skip ["DOS.BinToAtom"]
  defp stream_name(stage_id), do: :"stage_cards_#{stage_id}"

  # RE264 — the board URL this socket belongs to. On the story map, closing the drawer (or an
  # archive/review/answer that dismisses it) must land back on the map, not bounce the user to
  # the kanban board. Both take the **assigns map**, not the socket, so `render/1` can call
  # them for the drawer's close_patch with the `assigns` it already has.
  defp board_path(%{live_action: :story_map, board: board}), do: ~p"/board/#{board.slug}/story-map"
  defp board_path(%{board: board}), do: ~p"/board/#{board.slug}"

  defp card_path(%{live_action: :story_map, board: board}, ref), do: ~p"/board/#{board.slug}/story-map?card=#{ref}"

  defp card_path(%{board: board}, ref), do: ~p"/board/#{board.slug}?card=#{ref}"

  defp empty_compose_form, do: to_form(%{"title" => ""}, as: :card)

  defp empty_comment_form, do: to_form(%{"body" => ""}, as: :comment)

  defp empty_answer_form, do: to_form(%{"body" => ""}, as: :answer)

  # The panel shows the newest :needs_input question. A human-blocked card
  # (status control — no question recorded) yields nil, and the panel
  # renders with just the composer (spec edge case).
  defp latest_question(%Card{status: :needs_input}, activity) do
    Enum.find_value(activity, fn
      %Schemas.Activity{type: :needs_input, meta: meta} -> meta["question"]
      _entry -> nil
    end)
  end

  defp latest_question(_card, _activity), do: nil

  # RLY-71 — the structured payload behind the newest :needs_input block, or nil when that block
  # carries only a plain string (the drawer then renders the single-textarea fallback). Mirrors
  # latest_question/2: it looks at the newest :needs_input activity only.
  defp latest_questions(%Card{status: :needs_input}, activity) do
    case Enum.find(activity, &match?(%Schemas.Activity{type: :needs_input}, &1)) do
      %Schemas.Activity{meta: %{"questions" => questions}}
      when is_list(questions) and questions != [] ->
        questions

      _entry ->
        nil
    end
  end

  defp latest_questions(_card, _activity), do: nil

  defp conversation_dom_id(%Schemas.Comment{id: id}), do: "timeline-comment-#{id}"
  defp activity_dom_id(%Schemas.Activity{id: id}), do: "timeline-activity-#{id}"

  # RE277 — the Notes header shows a count, and LiveView streams cannot be counted.
  # These two helpers are the ONLY places :conversation is streamed, so the count
  # cannot drift from the list the drawer renders. @note_ids holds the note ids
  # rather than a running total so that, like the stream itself, both helpers are
  # idempotent per note id: re-applying an event (a duplicate broadcast, or a
  # drawer refresh that already recounted the note the following
  # :timeline_appended carries) can never inflate the header past the list.
  defp stream_notes(socket, comments) do
    socket
    |> stream(:conversation, comments, reset: true)
    |> assign(:note_ids, MapSet.new(comments, & &1.id))
  end

  defp insert_note(socket, comment) do
    socket
    |> stream_insert(:conversation, comment)
    |> update(:note_ids, &MapSet.put(&1, comment.id))
  end

  defp category_label(:unstarted), do: "Unstarted"
  defp category_label(:planning), do: "Planning"
  defp category_label(:in_progress), do: "In progress"
  defp category_label(:complete), do: "Complete"

  # The category band's total: every card in the category's main stages plus
  # their Review/Done sub-lanes.
  defp category_card_count(_category, stages, stage_counts, sublanes_by_parent) do
    Enum.reduce(stages, 0, fn stage, acc ->
      sub_total =
        sublanes_by_parent
        |> Map.get(stage.id, [])
        |> Enum.reduce(0, fn sub, sub_acc -> sub_acc + Map.fetch!(stage_counts, sub.id) end)

      acc + Map.fetch!(stage_counts, stage.id) + sub_total
    end)
  end

  # The small colored marker beside each category band, mirroring the mockup's
  # catMeta dots: a hollow ring (unstarted), a quarter-filled violet conic
  # (planning — where AI planning lives), a half-filled blue conic
  # (in progress), and a solid green disc (complete).
  defp category_dot_style(:unstarted),
    do:
      "width:9px;height:9px;border-radius:50%;border:1.5px solid oklch(0.68 0.02 255);box-sizing:border-box;display:block;flex:0 0 auto;"

  defp category_dot_style(:planning),
    do:
      "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-secondary) 0 25%, oklch(0.86 0.03 250) 25% 100%);display:block;flex:0 0 auto;"

  defp category_dot_style(:in_progress),
    do:
      "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-primary) 0 50%, oklch(0.86 0.03 250) 50% 100%);display:block;flex:0 0 auto;"

  defp category_dot_style(:complete),
    do: "width:9px;height:9px;border-radius:50%;background:var(--color-success);display:block;flex:0 0 auto;"

  defp agent_log_class(:error), do: "text-error"
  defp agent_log_class(:lifecycle), do: "text-base-content/60"
  defp agent_log_class(_), do: "text-base-content"
end
