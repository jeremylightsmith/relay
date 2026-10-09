defmodule RelayWeb.BoardSettingsLive do
  @moduledoc """
  Board settings (`/board/settings`) — the mockup's two-pane Board Settings
  (MMF 12): a 210px `BOARD` rail navigating between the **Stages** pane
  (rename / describe / reorder / add / delete stages, and the MMF 10b
  Review/Done sub-lane toggles) and the **API keys** pane (MMF 08, markup
  unchanged — restyling it is out of scope; General and Members arrive with
  MMFs 19/17).

  All stage mutations go through `Relay.Boards`, which broadcasts
  `{:stages_changed, board_id}` (MMF 18) so every open board re-renders
  live.

  RLY-46: each stage row carries a TYPE dropdown (`queue | work | planning |
  review | done`, `set_type` event, re-snaps resident cards to the new type's
  valid status). The old approval-gate toggle is gone: gating is now implicit
  in `type: :review`.

  RE431: the stage row owns its flow — there is no Flows tab (`?section=flows`
  lands on Stages). Each main stage ends in `RelayWeb.FlowSettingsComponents.flow_band/1`:
  the violet FLOW band (chip → editor, `v<n> · <m> nodes`, a direct On/Off
  toggle, the ⋯ menu with Open / Copy to another stage… / Reset / Delete) and
  the PULLS FROM → WORKS IN → LANDS ON row worked out from board order
  (`Relay.Flows.neighbours/2`), or the no-flow band, or the queue note.
  `refresh_stages/1` is the one reload point (`@stage_rows`, `@all_stages`,
  `@neighbours`), run after every mutation and on every `{:stages_changed, _}`.
  At most one inline panel is open, `@panel :: nil | {stage_id, kind}`; turning a
  flow on opens the RLY-182 readiness report as `{stage_id, :preflight}` when a
  check warns (it never blocks).

  RE429: a flow belongs to one stage, so deleting a stage deletes its flow, and a
  stage holding a flow can't be retyped to a non-work type (flashed refusal).
  RE431: the stage's × opens `{stage_id, :delete_stage}` — the inline red
  `FlowSettingsComponents.delete_stage_panel/1`, which names the flow it also
  deletes (`` This also deletes flow `ship` (v3 · 0 nodes) … ``); confirming
  (`confirm_delete_stage`) deletes both, and a `Boards.delete_stage/1` refusal
  shows inside the panel (`@panel_error`), not as a flash.

  RLY-57: a top-level review stage (`type: :review`, no `parent_id`) carries an
  "ON REJECT, SEND TO" dropdown (`set_reject_to` event) that persists
  `stage.reject_to_stage_id`; a review sub-lane always rejects back into its
  own parent stage and shows a fixed hint instead. When no `reject_to_stage_id`
  is set, the effective target falls back to `Boards.previous_main_stage/1`.

  RE432: a flow on a broken board shape is loud and one-click fixable. A paused flow's row
  (`Relay.Flows.paused?/1`) wears a thick amber border (`data-paused="true"`), a PAUSED badge, an
  amber chip and a dashed offending neighbour; every flow with a `Relay.Flows.Shape` problem —
  paused or merely disabled — gets `RelayWeb.FlowShapeComponents.shape_callout/1` under its row,
  and an "N flows are paused" summary links to the first paused row. A FIX button sends
  `"apply_shape_fix"` (`flow-key`, `index`, `action`); the handler re-reads the problem with
  `Flows.shape_problems/1` and applies `Enum.at(fixes, index)` only when its action still
  matches, so a stale page applies nothing. A refusal lands in `@shape_error ::
  nil | {flow_key, message}` inside that flow's callout.
  """

  use RelayWeb, :live_view

  import RelayWeb.CoreComponents, except: [section_label: 1]

  alias Phoenix.LiveView.JS
  alias Relay.ApiKeys
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Relay.Flows
  alias Relay.Members
  alias Relay.Runs
  alias RelayWeb.BoardCrumbs
  alias RelayWeb.ChangesetErrors
  alias RelayWeb.FlowSettingsComponents
  alias RelayWeb.FlowShapeComponents
  alias Schemas.ApiKey
  alias Schemas.Board
  alias Schemas.Membership
  alias Schemas.Stage
  alias Schemas.User

  @categories Stage.categories()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      wide
      crumbs={BoardCrumbs.settings_section(@board)}
    >
      <:title>
        <span id="settings-title" class="truncate" title={section_label(@section)}>
          {section_label(@section)}
        </span>
      </:title>
      <:actions>
        <.link
          navigate={~p"/board/#{@board.slug}"}
          id="settings-done"
          class="btn btn-sm btn-primary font-semibold"
        >
          Done
        </.link>
      </:actions>
      <div
        id="board-settings"
        class="flex flex-col drawer:flex-row"
        style="align-items:stretch;min-height:calc(100vh - 74px);"
      >
        <%!-- RLY-72: mobile-only (<720px) horizontal tab strip. Rendered first so on
             phones it sits under the page title with content full-width below; at
             >=720px `drawer:hidden` collapses it and the rail+content two-pane returns.
             No artboard — deliberate responsive design reusing the settings chrome. --%>
        <nav
          id="settings-tabs"
          class="flex drawer:hidden overflow-x-auto"
          style="border-bottom:1px solid var(--color-base-300);background:var(--color-base-200);padding:0 14px;gap:2px;"
        >
          <.link
            patch={~p"/board/#{@board.slug}/settings"}
            id="settings-tab-general"
            style={tab_style(@section == :general)}
          >
            {section_label(:general)}
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=stages"}
            id="settings-tab-stages"
            style={tab_style(@section == :stages)}
          >
            {section_label(:stages)}
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=public"}
            id="settings-tab-public"
            style={tab_style(@section == :public)}
          >
            {section_label(:public)}
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=members"}
            id="settings-tab-members"
            style={tab_style(@section == :members)}
          >
            {section_label(:members)}
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=keys"}
            id="settings-tab-keys"
            style={tab_style(@section == :keys)}
          >
            {section_label(:keys)}
          </.link>
          <.link
            navigate={~p"/board/#{@board.slug}/runners"}
            id="settings-tab-runners"
            style={tab_style(false)}
          >
            {section_label(:runners)}
          </.link>
        </nav>

        <%!-- Left rail — mockup "Relay Board.dc.html" lines ~176-183 --%>
        <nav
          id="settings-rail"
          class="hidden drawer:flex"
          style="width:210px;flex:0 0 auto;border-right:1px solid var(--color-base-300);background:var(--color-base-200);padding:22px 14px;flex-direction:column;gap:3px;"
        >
          <div
            class="font-mono"
            style="font-size:10px;font-weight:600;letter-spacing:0.08em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);padding:4px 10px 8px 10px;"
          >
            BOARD
          </div>
          <.link
            patch={~p"/board/#{@board.slug}/settings"}
            id="settings-nav-general"
            style={nav_style(@section == :general)}
          >
            {section_label(:general)}
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=stages"}
            id="settings-nav-stages"
            style={nav_style(@section == :stages)}
          >
            {section_label(:stages)}
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=public"}
            id="settings-nav-public"
            style={nav_style(@section == :public)}
          >
            {section_label(:public)}
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=members"}
            id="settings-nav-members"
            style={nav_style(@section == :members)}
          >
            {section_label(:members)}
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=keys"}
            id="settings-nav-keys"
            style={nav_style(@section == :keys)}
          >
            {section_label(:keys)}
          </.link>
          <div
            id="settings-flows-moved-note"
            class="mt-1 rounded-lg border border-dashed border-base-300 px-2.5 py-1.5 text-[11px] leading-snug text-base-content/50"
          >
            Flows moved into <b class="text-base-content/70">Stages</b>
            — each stage row owns its flow.
          </div>

          <div
            class="font-mono"
            style="font-size:10px;font-weight:600;letter-spacing:0.08em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);padding:18px 10px 8px 10px;"
          >
            ENGINE
          </div>
          <.link
            navigate={~p"/board/#{@board.slug}/runners"}
            id="settings-nav-runners"
            style={nav_style(false)}
          >
            {section_label(:runners)}
          </.link>
        </nav>

        <%!-- Content pane — mockup lines ~186-187 --%>
        <div style="flex:1;overflow-y:auto;background:var(--color-base-200);">
          <div style="max-width:760px;margin:0 auto;padding:34px 40px 84px 40px;">
            <section :if={@section == :public} id="public-pane">
              <.page_heading class="mb-1">
                Public board
              </.page_heading>
              <p style="font-size:14px;line-height:1.55;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);margin:0 0 28px 0;max-width:560px;">
                Open a read-only version of this board to the public. Anyone can browse it and upvote ideas — the ones with the most support rise to the top.
              </p>

              <.form for={@public_form} id="public-settings-form" phx-change="save_public_settings">
                <div style="display:flex;align-items:center;gap:16px;background:var(--color-base-100);border:1px solid var(--color-base-300);border-radius:12px;padding:16px 18px;">
                  <div style="flex:1;">
                    <div style="font-size:14px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);">
                      Enable public board
                    </div>
                    <div style="font-size:12.5px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);margin-top:2px;">
                      When on, the public URL below is live.
                    </div>
                  </div>
                  <label style="cursor:pointer;">
                    <input
                      type="checkbox"
                      name="board[public_enabled]"
                      id="public-enabled-toggle"
                      value="true"
                      checked={@board.public_enabled}
                      class="toggle toggle-secondary"
                    />
                  </label>
                </div>

                <div
                  :if={@board.public_enabled}
                  style="display:flex;flex-direction:column;gap:26px;margin-top:24px;"
                >
                  <div style="display:flex;flex-direction:column;gap:8px;">
                    <label style="font-size:12px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);">
                      Public URL
                    </label>
                    <div
                      id="public-url-row"
                      style="max-width:460px;display:flex;align-items:center;border:1px solid var(--color-field-border);border-radius:9px;padding:10px 12px;background:var(--color-field-bg);font-size:13.5px;font-family:'JetBrains Mono',ui-monospace,monospace;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);"
                    >
                      {"#{RelayWeb.Endpoint.url()}/board/#{@board.slug}/public"}
                    </div>
                  </div>

                  <div style="display:flex;flex-direction:column;gap:10px;">
                    <label style="font-size:12px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);">
                      New public ideas arrive in
                    </label>
                    <p style="font-size:12.5px;line-height:1.5;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);margin:0 0 2px 0;max-width:520px;">
                      When someone posts on the public board, Relay creates a card in this stage.
                    </p>
                    <div
                      id="intake-stage-picker"
                      style="display:flex;flex-direction:column;gap:6px;max-width:460px;"
                    >
                      <label
                        :for={stage <- main_stages_for_intake(@board.stages)}
                        style={intake_row_style(@board.public_intake_stage_id == stage.id)}
                      >
                        <input
                          type="radio"
                          name="board[public_intake_stage_id]"
                          value={stage.id}
                          checked={@board.public_intake_stage_id == stage.id}
                          class="radio radio-sm radio-secondary"
                        />
                        <span style="font-size:13.5px;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);flex:1;">
                          {stage.name}
                        </span>
                      </label>
                    </div>
                  </div>
                </div>
              </.form>
            </section>

            <section :if={@section == :general} id="general-pane">
              <.page_heading class="mb-1.5">
                General
              </.page_heading>
              <p style="font-size:14px;line-height:1.55;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);margin:0 0 18px 0;max-width:560px;">
                The board's display name, its URL slug (relay.app/&lt;slug&gt;), and its card key.
              </p>
              <div style="display:flex;flex-direction:column;gap:22px;max-width:420px;">
                <div>
                  <label style="font-size:12px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);">
                    Board name
                  </label>
                  <.boxed_field
                    :if={!@read_only?}
                    id="board-name"
                    value={@board.name}
                    form={@general_form}
                    field={:name}
                    save_event="save_board_name"
                    cancel_event="cancel_board_name"
                  />
                  <span :if={@read_only?} style="font-size:14px;">{@board.name}</span>
                </div>
                <div style="display:flex;flex-direction:column;gap:8px;">
                  <label style="font-size:12px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);">
                    Board URL
                  </label>
                  <.boxed_field
                    :if={!@read_only?}
                    id="board-slug"
                    value={@board.slug}
                    form={@general_form}
                    field={:slug}
                    prefix="relay.app/"
                    save_event="save_board_slug"
                    cancel_event="cancel_board_slug"
                  />
                  <span :if={@read_only?} class="font-mono" style="font-size:14px;">
                    relay.app/{@board.slug}
                  </span>
                </div>
                <div style="display:flex;flex-direction:column;gap:8px;">
                  <label style="font-size:12px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);">
                    Card key
                  </label>
                  <.boxed_field
                    :if={!@read_only?}
                    id="board-key"
                    value={@board.key}
                    form={@general_form}
                    field={:key}
                    save_event="save_board_key"
                    cancel_event="cancel_board_key"
                  />
                  <span :if={@read_only?} class="font-mono" style="font-size:14px;">
                    {@board.key}
                  </span>
                  <p
                    id="board-key-warning"
                    style="font-size:12px;line-height:1.5;color:color-mix(in oklab, var(--color-warning) 65%, var(--color-base-content));margin:0;"
                  >
                    Changing this renames every card on this board (e.g. {@board.key}230).
                  </p>
                </div>
              </div>

              <div
                :if={!@read_only?}
                id="danger-zone"
                style="margin-top:44px;border:1px solid color-mix(in oklab, var(--color-error) 25%, var(--color-base-100));border-radius:12px;padding:18px 20px;background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));max-width:560px;"
              >
                <div style="font-size:13px;font-weight:600;color:color-mix(in oklab, var(--color-error) 55%, var(--color-base-content));margin-bottom:4px;">
                  Danger zone
                </div>
                <div style="display:flex;align-items:center;gap:16px;">
                  <%!-- `oklch 0.50 0.04 15` is a muted warm grey, not a red: C 0.04 is a Rule-N
                    near-neutral (see `delete_style/1` in story_map_components.ex). Rule B needed
                    `error` at 65% to reach L 0.50, landing at C 0.10 — a clear red this body copy
                    never was; the "Danger zone" heading above carries the warning. --%>
                  <span style="font-size:13px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);flex:1;">
                    Archiving hides this board for everyone. You can restore it later.
                  </span>
                  <.button
                    type="button"
                    id="archive-board-button"
                    phx-click="archive_board"
                    data-confirm="Archive this board?"
                    class=""
                    style="background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 35%, var(--color-base-100));color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));border-radius:8px;padding:8px 14px;font-size:13px;font-weight:600;cursor:pointer;"
                    pending="Archiving…"
                  >
                    Archive board
                  </.button>
                </div>
              </div>
            </section>

            <section :if={@section == :stages} id="stages-pane">
              <.page_heading class="mb-1.5">
                Stages
              </.page_heading>
              <%!-- Mockup line ~217. --%>
              <p style="font-size:14px;line-height:1.55;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);margin:0 0 12px 0;max-width:560px;">
                Stages live inside four categories — <b style="color:color-mix(in oklab, var(--color-base-content) 90%, transparent);">Unstarted</b>, <b style="color:color-mix(in oklab, var(--color-base-content) 90%, transparent);">Planning</b>, <b style="color:color-mix(in oklab, var(--color-base-content) 90%, transparent);">In progress</b>, and
                <b style="color:color-mix(in oklab, var(--color-base-content) 90%, transparent);">
                  Complete
                </b>
                — so everyone knows what a stage <i>means</i>. Use the arrows to move a stage
                up or down — cross into another category and it takes on that meaning. Each stage
                can have <b style="color:color-mix(in oklab, var(--color-base-content) 90%, transparent);">one AI flow</b>: it pulls from the column before the stage and lands on the
                column after it — reorder stages and the flow follows.
              </p>

              <div
                :if={@paused_stage_ids != []}
                id="stages-paused-summary"
                class="mb-2 mt-4 flex items-center gap-3 rounded-lg px-4 py-2.5 text-[13px]"
                style="background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 50%, var(--color-base-100));color:color-mix(in oklab, var(--color-warning) 30%, var(--color-base-content));"
              >
                <span class="font-bold">!</span>
                <a
                  id="stages-paused-summary-link"
                  href={"#stage-#{hd(@paused_stage_ids)}-row"}
                  class="flex-1"
                >
                  <b>{paused_count_label(length(@paused_stage_ids))}</b>
                  because of how the board is laid out. Each highlighted stage below says what's wrong and how to fix it.
                </a>
              </div>

              <%!-- All four groups always render so an emptied category stays reachable. --%>
              <div
                :for={{category, stages} <- @stage_groups}
                id={"settings-group-#{category}"}
                style="margin-top:22px;"
              >
                <div style="display:flex;align-items:center;gap:8px;margin:0 0 10px 2px;">
                  <span class="category-dot" style={category_dot_style(category)}></span>
                  <span
                    class="font-mono"
                    style="font-size:10.5px;font-weight:600;letter-spacing:0.09em;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);"
                  >
                    {category_band_label(category)}
                  </span>
                  <span
                    class="font-mono"
                    style="font-size:10.5px;color:color-mix(in oklab, var(--color-base-content) 45%, transparent);"
                  >
                    {length(stages)}
                  </span>
                </div>
                <div style="display:flex;flex-direction:column;gap:12px;">
                  <div
                    :for={stage <- stages}
                    id={"stage-#{stage.id}-row"}
                    data-paused={to_string(stage.id in @paused_stage_ids)}
                    style={stage_row_style(stage.id in @paused_stage_ids)}
                  >
                    <div style="display:flex;align-items:center;gap:10px;">
                      <.stage_type_icon type={stage.type} />
                      <div style="flex:1;">
                        <.inline_field
                          id={"stage-#{stage.id}-name"}
                          value={stage.name}
                          editing={@editing_stage == {stage.id, "name"}}
                          form={@stage_form}
                          field={:name}
                          edit_event="edit_stage"
                          cancel_event="cancel_stage"
                          save_event="save_stage"
                          edit_attrs={
                            %{"phx-value-stage-id" => stage.id, "phx-value-field" => "name"}
                          }
                          read_class="text-[15px] font-semibold tracking-[-0.01em]"
                        >
                          <:hidden>
                            <input type="hidden" name="stage_id" value={stage.id} />
                          </:hidden>
                        </.inline_field>
                      </div>
                      <div style="display:flex;align-items:center;gap:2px;">
                        <button
                          type="button"
                          id={"stage-#{stage.id}-up"}
                          phx-click="reorder_stage"
                          phx-value-stage-id={stage.id}
                          phx-value-direction="up"
                          title="Move up"
                          style="width:26px;height:26px;border-radius:6px;border:1px solid var(--color-base-300);background:var(--color-base-100);color:color-mix(in oklab, var(--color-base-content) 70%, transparent);font-size:12px;padding:0;"
                        >
                          ↑
                        </button>
                        <button
                          type="button"
                          id={"stage-#{stage.id}-down"}
                          phx-click="reorder_stage"
                          phx-value-stage-id={stage.id}
                          phx-value-direction="down"
                          title="Move down"
                          style="width:26px;height:26px;border-radius:6px;border:1px solid var(--color-base-300);background:var(--color-base-100);color:color-mix(in oklab, var(--color-base-content) 70%, transparent);font-size:12px;padding:0;"
                        >
                          ↓
                        </button>
                        <button
                          type="button"
                          id={"stage-#{stage.id}-delete"}
                          phx-click="delete_stage"
                          phx-value-stage-id={stage.id}
                          title="Delete stage"
                          style="width:26px;height:26px;border-radius:6px;border:1px solid color-mix(in oklab, var(--color-error) 25%, var(--color-base-100));background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));color:color-mix(in oklab, var(--color-error) 80%, var(--color-base-content));font-size:14px;padding:0;margin-left:4px;"
                        >
                          ×
                        </button>
                      </div>
                    </div>
                    <FlowSettingsComponents.delete_stage_panel
                      :if={panel_kind(@panel, stage.id) == :delete_stage}
                      stage={stage}
                      flow={@stage_rows[stage.id] && @stage_rows[stage.id].flow}
                      error={@panel_error}
                    />
                    <.boxed_field
                      id={"stage-#{stage.id}-description"}
                      value={stage.description}
                      placeholder="Describe what happens in this stage…"
                      multiline
                      rows="3"
                      editing={@editing_stage == {stage.id, "description"}}
                      form={@stage_form}
                      field={:description}
                      edit_event="edit_stage"
                      cancel_event="cancel_stage"
                      save_event="save_stage"
                      edit_attrs={
                        %{"phx-value-stage-id" => stage.id, "phx-value-field" => "description"}
                      }
                    >
                      <:hidden>
                        <input type="hidden" name="stage_id" value={stage.id} />
                      </:hidden>
                    </.boxed_field>
                    <%!-- TYPE dropdown (RLY-46). --%>
                    <div style="display:flex;align-items:center;gap:20px;flex-wrap:wrap;">
                      <div style="display:flex;align-items:center;gap:9px;">
                        <span
                          class="font-mono"
                          style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                        >
                          TYPE
                        </span>
                        <details class="dropdown" id={"stage-#{stage.id}-type-dropdown"}>
                          <summary class="btn btn-sm btn-outline gap-2">
                            <.stage_type_icon type={stage.type} />
                            {type_label(stage.type)}
                          </summary>
                          <ul class="menu dropdown-content z-10 w-44 rounded-box bg-base-100 p-1 shadow">
                            <li :for={t <- [:queue, :work, :planning, :review, :done]}>
                              <button
                                type="button"
                                id={"stage-#{stage.id}-type-#{t}"}
                                phx-click="set_type"
                                phx-value-stage-id={stage.id}
                                phx-value-type={t}
                                class="flex items-center gap-2"
                              >
                                <.stage_type_icon type={t} />
                                <span class="flex-1 text-left">{type_label(t)}</span>
                                <.icon :if={t == stage.type} name="hero-check" class="size-4" />
                              </button>
                            </li>
                          </ul>
                        </details>
                      </div>
                      <%!-- COLLAPSED toggle (RLY-111) — board-wide default-collapse; any stage type. --%>
                      <div style="display:flex;align-items:center;gap:9px;">
                        <span
                          class="font-mono"
                          style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                        >
                          COLLAPSED
                        </span>
                        <input
                          id={"stage-#{stage.id}-collapsed-toggle"}
                          type="checkbox"
                          class="toggle toggle-sm"
                          checked={stage.collapsed_by_default}
                          phx-click="toggle_collapsed_default"
                          phx-value-stage-id={stage.id}
                        />
                      </div>
                    </div>
                    <%!-- Controls row — WIP (MMF 11). --%>
                    <div style="display:flex;align-items:center;gap:20px;flex-wrap:wrap;">
                      <div style="display:flex;align-items:center;gap:9px;">
                        <span
                          class="font-mono"
                          style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                        >
                          WIP
                        </span>
                        <button
                          type="button"
                          id={"stage-#{stage.id}-wip-toggle"}
                          phx-click="toggle_wip"
                          phx-value-stage-id={stage.id}
                          style={wip_toggle_style(stage.wip_limit != nil)}
                        >
                          {if stage.wip_limit, do: "On", else: "Off"}
                        </button>
                        <div
                          :if={stage.wip_limit}
                          style="display:inline-flex;align-items:center;border:1px solid var(--color-field-border);border-radius:8px;overflow:hidden;"
                        >
                          <button
                            type="button"
                            id={"stage-#{stage.id}-wip-down"}
                            phx-click="bump_wip"
                            phx-value-stage-id={stage.id}
                            phx-value-delta="-1"
                            aria-label="Decrease WIP limit"
                            style="width:26px;height:30px;border:none;background:var(--color-base-200);color:color-mix(in oklab, var(--color-base-content) 70%, transparent);font-size:15px;padding:0;"
                          >
                            −
                          </button>
                          <span
                            id={"stage-#{stage.id}-wip-value"}
                            class="font-mono"
                            style="width:32px;text-align:center;font-size:13px;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"
                          >
                            {stage.wip_limit}
                          </span>
                          <button
                            type="button"
                            id={"stage-#{stage.id}-wip-up"}
                            phx-click="bump_wip"
                            phx-value-stage-id={stage.id}
                            phx-value-delta="1"
                            aria-label="Increase WIP limit"
                            style="width:26px;height:30px;border:none;background:var(--color-base-200);color:color-mix(in oklab, var(--color-base-content) 70%, transparent);font-size:15px;padding:0;"
                          >
                            +
                          </button>
                        </div>
                      </div>
                    </div>
                    <div
                      :if={stage.type == :review and is_nil(stage.parent_id)}
                      style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;border-top:1px dashed var(--color-base-300);padding-top:12px;"
                    >
                      <span
                        class="font-mono"
                        style="font-size:11px;color:color-mix(in oklab, var(--color-accent) 50%, var(--color-base-content));"
                      >
                        ON REJECT, SEND TO
                      </span>
                      <details class="dropdown" id={"stage-#{stage.id}-reject-route"}>
                        <summary
                          class="btn btn-sm btn-outline gap-2"
                          style="color:color-mix(in oklab, var(--color-accent) 20%, var(--color-base-content));border-color:color-mix(in oklab, var(--color-accent) 35%, var(--color-base-100));"
                        >
                          <span style="width:7px;height:7px;border-radius:2px;background:var(--color-accent);">
                          </span>
                          {reject_route_name(stage, @stages)}
                        </summary>
                        <ul class="menu dropdown-content z-10 w-44 rounded-box bg-base-100 p-1 shadow">
                          <li :for={opt <- reject_route_options(stage, @stages)}>
                            <button
                              type="button"
                              id={"stage-#{stage.id}-reject-to-#{opt.id}"}
                              phx-click="set_reject_to"
                              phx-value-stage-id={stage.id}
                              phx-value-target-id={opt.id}
                              class="flex items-center gap-2"
                            >
                              <span class="flex-1 text-left">{opt.name}</span>
                              <.icon
                                :if={opt.id == effective_reject_to(stage)}
                                name="hero-check"
                                class="size-4"
                              />
                            </button>
                          </li>
                        </ul>
                      </details>
                      <span style="flex:1;min-width:180px;font-size:11px;line-height:1.4;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);">
                        Rejected cards return here to be re-planned — the reviewer doesn't choose a destination.
                      </span>
                    </div>
                    <div
                      id={"stage-#{stage.id}-sublanes"}
                      style="display:flex;align-items:center;gap:24px;flex-wrap:wrap;border-top:1px dashed var(--color-base-300);padding-top:12px;"
                    >
                      <div style="display:flex;align-items:center;gap:10px;">
                        <span
                          class="font-mono"
                          style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                        >
                          REVIEW SUB-LANE
                        </span>
                        <input
                          id={toggle_id(@lane_nonce, stage.id, :review)}
                          type="checkbox"
                          class="toggle toggle-sm"
                          checked={lane_on?(@lane_map, stage.id, :review)}
                          phx-click="toggle_lane"
                          phx-value-stage-id={stage.id}
                          phx-value-lane="review"
                        />
                      </div>
                      <div style="display:flex;align-items:center;gap:10px;">
                        <span
                          class="font-mono"
                          style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                        >
                          DONE SUB-LANE
                        </span>
                        <input
                          id={toggle_id(@lane_nonce, stage.id, :done)}
                          type="checkbox"
                          class="toggle toggle-sm"
                          checked={lane_on?(@lane_map, stage.id, :done)}
                          phx-click="toggle_lane"
                          phx-value-stage-id={stage.id}
                          phx-value-lane="done"
                        />
                      </div>
                      <span style="flex:1;min-width:180px;font-size:11px;line-height:1.4;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);">
                        Both are optional lanes at the end of a stage —
                        <b style="color:color-mix(in oklab, var(--color-base-content) 80%, transparent);">
                          Review
                        </b>
                        holds finished work for a human to approve or reject;
                        <b style="color:color-mix(in oklab, var(--color-base-content) 80%, transparent);">
                          Done
                        </b>
                        parks it, ready for the next stage to pull.
                      </span>
                    </div>
                    <span
                      :if={lane_on?(@lane_map, stage.id, :review)}
                      style="font-size:11px;line-height:1.4;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
                    >
                      A review sub-lane always rejects back into its own stage — nothing to configure.
                    </span>
                    <%!-- RE431 — the stage row owns its flow: the FLOW band (or no-flow band / queue note). --%>
                    <FlowSettingsComponents.flow_band
                      stage={stage}
                      row={Map.get(@stage_rows, stage.id)}
                      neighbours={Map.fetch!(@neighbours, stage.id)}
                      slug={@board.slug}
                      panel={panel_kind(@panel, stage.id)}
                      preflight={@flow_preflight}
                      read_only?={@read_only?}
                      copy_targets={@copy_targets}
                    >
                      <FlowSettingsComponents.add_flow_panel
                        :if={panel_kind(@panel, stage.id) == :add}
                        stage={stage}
                        form={@add_form}
                        addable_defaults={@addable_defaults}
                        neighbours={Map.fetch!(@neighbours, stage.id)}
                      />
                    </FlowSettingsComponents.flow_band>
                    <FlowSettingsComponents.copy_flow_panel
                      :if={
                        panel_kind(@panel, stage.id) == :copy and Map.has_key?(@stage_rows, stage.id)
                      }
                      flow={@stage_rows[stage.id].flow}
                      form={@copy_form}
                      targets={@copy_targets}
                      copy_key={@copy_key}
                    />
                    <%!-- RE432 — the broken-shape callout: WHAT / WHY / BOARD ORDER / one-click FIX. --%>
                    <FlowShapeComponents.shape_callout
                      :if={problem = row_problem(@stage_rows, stage.id)}
                      id={"stage-#{stage.id}-shape-callout"}
                      problem={problem}
                      error={shape_error_for(@shape_error, problem.flow_key)}
                      read_only?={@read_only?}
                    />
                  </div>
                </div>
                <button
                  type="button"
                  id={"add-stage-#{category}"}
                  phx-click="add_stage"
                  phx-value-category={category}
                  style="margin-top:10px;width:100%;border:1px dashed color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100));background:var(--color-base-100);color:color-mix(in oklab, var(--color-base-content) 70%, transparent);border-radius:11px;padding:11px;font-size:12.5px;font-weight:600;"
                >
                  + Add stage to {category_band_label(category)}
                </button>
              </div>
            </section>

            <section :if={@section == :members} id="members-pane">
              <.page_heading class="mb-1">
                Members
              </.page_heading>
              <p style="font-size:14px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);margin:0 0 26px 0;">
                People with access to this board — and the AI agent that works alongside them.
              </p>

              <.form
                :let={f}
                for={@invite_form}
                id="invite-member-form"
                class="action-group"
                as={:invite}
                phx-submit="invite_member"
                style="background:var(--color-base-100);border:1px solid var(--color-base-300);border-radius:12px;padding:16px;display:flex;align-items:center;gap:10px;margin-bottom:26px;flex-wrap:wrap;"
              >
                <input
                  type="email"
                  id="invite-email"
                  name={f[:email].name}
                  value={Phoenix.HTML.Form.normalize_value("email", f[:email].value)}
                  placeholder="name@company.com"
                  autocomplete="off"
                  style="flex:1;min-width:180px;border:1px solid var(--color-field-border);border-radius:8px;padding:9px 11px;font-size:13.5px;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);background:var(--color-field-bg);outline:none;"
                />
                <.button
                  type="submit"
                  id="send-invite"
                  class=""
                  style="background:var(--color-primary);color:var(--color-primary-content);border:none;border-radius:8px;padding:9px 16px;font-size:13.5px;font-weight:600;"
                  pending="Sending…"
                >
                  Send invite
                </.button>
              </.form>

              <div
                class="font-mono"
                style="font-size:10px;font-weight:600;letter-spacing:0.08em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);margin-bottom:10px;"
              >
                PEOPLE · {@member_count}
              </div>
              <div style="background:var(--color-base-100);border:1px solid var(--color-base-300);border-radius:12px;overflow:hidden;margin-bottom:28px;">
                <div
                  :for={m <- @members}
                  id={"member-row-#{m.id}"}
                  style="display:flex;align-items:center;gap:12px;padding:13px 16px;border-top:1px solid color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100));"
                >
                  <.avatar
                    size={34}
                    tint={:identity}
                    src={m.user && m.user.avatar_url}
                    name={m.user && m.user.name}
                    email={m.email}
                  />
                  <div style="flex:1;min-width:0;display:flex;flex-direction:column;gap:2px;">
                    <div style="display:flex;align-items:center;gap:8px;">
                      <span style="font-size:14px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);">
                        {member_name(m)}
                      </span>
                      <span
                        :if={mine?(m, @current_scope)}
                        class="font-mono"
                        style="font-size:10px;font-weight:600;letter-spacing:0.04em;background:color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100));color:color-mix(in oklab, var(--color-primary) 55%, var(--color-base-content));padding:2px 6px;border-radius:5px;"
                      >
                        YOU
                      </span>
                      <span
                        :if={is_nil(m.user_id)}
                        class="font-mono"
                        style="font-size:10px;font-weight:600;letter-spacing:0.04em;background:color-mix(in oklab, var(--color-warning) 15%, var(--color-base-100));color:color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content));padding:2px 6px;border-radius:5px;"
                      >
                        INVITED
                      </span>
                    </div>
                    <span
                      class="font-mono"
                      style="font-size:12.5px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
                    >
                      {m.email}
                    </span>
                  </div>
                  <button
                    :if={!mine?(m, @current_scope)}
                    type="button"
                    id={"remove-member-#{m.id}"}
                    phx-click="remove_member"
                    phx-value-id={m.id}
                    data-confirm="Remove this member from the board?"
                    title="Remove"
                    style="width:28px;height:28px;border-radius:7px;border:1px solid var(--color-base-300);background:var(--color-base-100);color:color-mix(in oklab, var(--color-base-content) 65%, transparent);font-size:15px;line-height:1;padding:0;flex:0 0 auto;"
                  >
                    ×
                  </button>
                  <span :if={mine?(m, @current_scope)} style="width:28px;flex:0 0 auto;"></span>
                </div>
              </div>

              <div
                class="font-mono"
                style="font-size:10px;font-weight:600;letter-spacing:0.08em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);margin-bottom:10px;"
              >
                AGENT
              </div>
              <div
                id="agent-card"
                style="background:color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-secondary) 20%, var(--color-base-100));border-radius:12px;padding:16px;display:flex;align-items:center;gap:13px;"
              >
                <div style="width:38px;height:38px;border-radius:50%;background:var(--color-secondary);display:flex;align-items:center;justify-content:center;flex:0 0 auto;">
                  <span style="width:14px;height:14px;border-radius:50%;border:2px solid var(--color-secondary-content);">
                  </span>
                </div>
                <div style="flex:1;min-width:0;">
                  <div style="font-size:14px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);">
                    Relay AI
                  </div>
                  <%!-- `oklch 0.50 0.03 292` is a grey-violet, not a violet: C 0.03 is a Rule-N near-neutral
                    (see `delete_style/1` in story_map_components.ex), and Rule B's ink formula would
                    have to run `secondary` to 80% to reach L 0.50, landing at C 0.13. --%>
                  <div style="font-size:12.5px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
                    Runs the AI-owned stages · authenticated with an API key
                  </div>
                </div>
                <.link
                  patch={~p"/board/#{@board.slug}/settings?section=keys"}
                  id="agent-manage-key"
                  style="background:var(--color-base-100);border:1px solid color-mix(in oklab, var(--color-secondary) 25%, var(--color-base-100));color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));border-radius:8px;padding:8px 14px;font-size:13px;font-weight:600;flex:0 0 auto;text-decoration:none;"
                >
                  Manage key →
                </.link>
              </div>
            </section>

            <section :if={@section == :keys} id="api-key-pane">
              <.page_heading class="mb-1">
                API keys
              </.page_heading>
              <p style="font-size:14px;line-height:1.55;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);margin:0 0 24px 0;max-width:520px;">
                Give a key to your agent so it can read the board, move cards, post progress, and
                ask questions on the AI-owned stages. Treat it like a password.
              </p>

              <div style="display:flex;align-items:center;gap:11px;background:color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-secondary) 20%, var(--color-base-100));border-radius:10px;padding:12px 14px;margin-bottom:22px;">
                <div style="width:26px;height:26px;border-radius:50%;background:var(--color-secondary);display:flex;align-items:center;justify-content:center;flex:0 0 auto;">
                  <span style="width:10px;height:10px;border-radius:50%;border:1.5px solid var(--color-secondary-content);">
                  </span>
                </div>
                <%!-- `oklch 0.44 0.06 292` is a violet-tinted grey, not violet ink: a Rule-N
                  near-neutral (see `delete_style/1` in story_map_components.ex). Rule B needed
                  `secondary` at 60% to reach L 0.44, landing at C 0.10 — the violet AI dot beside
                  it carries the signal, not this caption. --%>
                <span style="font-size:13px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
                  These keys authenticate <b>Relay AI</b> on this board.
                </span>
              </div>

              <div id="api-key-list" style="display:flex;flex-direction:column;gap:12px;">
                <div
                  :for={key <- @api_keys}
                  id={"api-key-#{key.id}"}
                  style="background:var(--color-base-100);border:1px solid var(--color-base-300);border-radius:12px;padding:16px 18px;display:flex;flex-direction:column;gap:12px;"
                >
                  <div
                    id={"api-key-row-#{key.id}"}
                    class="action-group"
                    style="display:flex;align-items:center;gap:10px;"
                  >
                    <div id={"api-key-name-#{key.id}"} style="flex:1;min-width:0;">
                      <.boxed_field
                        :if={!@read_only?}
                        id={"api-key-name-#{key.id}"}
                        form={@key_forms[key.id]}
                        field={:name}
                        input_class="font-semibold"
                        save_event="rename_key"
                        cancel_event="cancel_rename_key"
                      >
                        <:hidden><input type="hidden" name="key_id" value={key.id} /></:hidden>
                      </.boxed_field>
                      <span
                        :if={@read_only?}
                        style="font-size:14px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"
                      >
                        {key.name}
                      </span>
                    </div>
                    <.button
                      id={"regenerate-key-#{key.id}"}
                      type="button"
                      phx-click="regenerate_key"
                      phx-value-id={key.id}
                      data-confirm="Regenerate the key? The current key stops working immediately."
                      class=""
                      style="background:transparent;border:1px solid var(--color-base-300);color:color-mix(in oklab, var(--color-base-content) 70%, transparent);border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;flex:0 0 auto;"
                      pending="Regenerating…"
                    >
                      Regenerate
                    </.button>
                    <.button
                      id={"revoke-key-#{key.id}"}
                      type="button"
                      phx-click="revoke_key"
                      phx-value-id={key.id}
                      data-confirm="Revoke the key? Tools using it will lose access."
                      class=""
                      style="background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 25%, var(--color-base-100));color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;flex:0 0 auto;"
                      pending="Revoking…"
                    >
                      Revoke
                    </.button>
                  </div>

                  <div :if={@revealed && @revealed.key_id == key.id} id="api-key-reveal">
                    <div
                      id="api-key-reveal-note"
                      class="font-mono"
                      style="font-size:11.5px;color:color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content));margin-bottom:6px;"
                    >
                      Copy this key now — you won't be able to see it again.
                    </div>
                    <div style="display:flex;align-items:center;gap:8px;background:var(--color-base-200);border:1px solid var(--color-base-300);border-radius:9px;padding:10px 12px;">
                      <code
                        id="api-key-secret"
                        class="font-mono"
                        style="flex:1;min-width:0;font-size:13px;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
                      >
                        {@revealed.token}
                      </code>
                      <button
                        id="copy-key"
                        type="button"
                        phx-hook=".CopyKey"
                        data-target="api-key-secret"
                        style="background:var(--color-field-hover);border:1px solid var(--color-base-300);color:color-mix(in oklab, var(--color-base-content) 80%, transparent);border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;flex:0 0 auto;"
                      >
                        Copy
                      </button>
                    </div>
                  </div>

                  <div style="display:flex;align-items:center;gap:8px;background:var(--color-base-200);border:1px solid var(--color-base-300);border-radius:9px;padding:10px 12px;">
                    <span
                      id={"api-key-masked-#{key.id}"}
                      class="font-mono"
                      style="flex:1;min-width:0;font-size:13px;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
                    >
                      {masked(key)}
                    </span>
                  </div>
                  <div
                    class="font-mono"
                    style="font-size:11.5px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                  >
                    <span id={"api-key-created-#{key.id}"}>
                      Created {format_time(key.inserted_at)}
                    </span>
                    · <span id={"api-key-last-used-#{key.id}"}>last used {last_used(key)}</span>
                  </div>
                </div>
              </div>

              <button
                :if={!@new_key_form}
                id="generate-key"
                type="button"
                phx-click="new_key"
                style="margin-top:14px;border:1px dashed color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100));background:var(--color-base-100);color:color-mix(in oklab, var(--color-base-content) 75%, transparent);border-radius:11px;padding:11px 16px;font-size:13px;font-weight:600;"
              >
                + Create new key
              </button>
              <.form
                :if={@new_key_form}
                for={@new_key_form}
                id="new-key-form"
                class="action-group"
                phx-submit="create_key"
                style="margin-top:14px;display:flex;align-items:flex-start;gap:8px;max-width:520px;"
              >
                <div style="flex:1;min-width:0;">
                  <.input
                    field={@new_key_form[:name]}
                    type="text"
                    id="new-key-name"
                    placeholder="e.g. Mac mini"
                    autocomplete="off"
                    phx-mounted={JS.focus()}
                  />
                </div>
                <.button
                  type="submit"
                  id="create-key-submit"
                  class="btn btn-sm btn-primary"
                  pending="Creating…"
                >
                  Create
                </.button>
                <button
                  type="button"
                  id="cancel-new-key"
                  phx-click="cancel_new_key"
                  class="btn btn-sm"
                >
                  Cancel
                </button>
              </.form>

              <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyKey">
                export default {
                  mounted() {
                    this.el.addEventListener("click", () => {
                      const target = document.getElementById(this.el.dataset.target)
                      if (!target) return
                      navigator.clipboard.writeText(target.textContent.trim())
                      const label = this.el.dataset.label || this.el.textContent.trim()
                      this.el.dataset.label = label
                      this.el.textContent = "Copied ✓"
                      this.el.style.background = "color-mix(in oklab, var(--color-success) 15%, var(--color-base-100))"
                      this.el.style.borderColor = "color-mix(in oklab, var(--color-success) 50%, var(--color-base-100))"
                      this.el.style.color = "color-mix(in oklab, var(--color-success) 45%, var(--color-base-content))"
                      clearTimeout(this._t)
                      this._t = setTimeout(() => {
                        this.el.textContent = label
                        this.el.style.background = "var(--color-field-hover)"
                        this.el.style.borderColor = "var(--color-base-300)"
                        this.el.style.color = "color-mix(in oklab, var(--color-base-content) 80%, transparent)"
                      }, 1600)
                    })
                  }
                }
              </script>

              <div style="margin-top:26px;font-size:12.5px;line-height:1.55;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);">
                Keys are shown in full only right after they're created or regenerated. Store them
                somewhere safe — anyone with a key can act as your agent.
              </div>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    board = Boards.get_board!(socket.assigns.current_scope.user, slug)

    if connected?(socket), do: Events.subscribe(board.id)

    {:ok,
     socket
     |> assign(:page_title, "Board settings")
     |> assign(:board, board)
     |> assign(:revealed, nil)
     |> assign(:new_key_form, nil)
     |> assign_keys(ApiKeys.list_keys(board))
     |> assign(:lane_nonce, %{})
     |> assign(:general_form, to_form(Boards.change_board(board)))
     |> assign(:public_form, to_form(Board.public_settings_changeset(board, %{})))
     |> assign(:read_only?, Board.archived?(board))
     |> assign(:editing_stage, nil)
     |> assign(:stage_form, nil)
     |> assign(:invite_form, to_form(%{"email" => ""}, as: :invite))
     |> assign(:panel, nil)
     |> assign(:flow_preflight, nil)
     |> assign(:panel_error, nil)
     |> assign(:shape_error, nil)
     |> assign(:copy_form, to_form(%{}, as: :copy))
     |> assign(:copy_key, nil)
     |> assign(:add_form, to_form(%{}, as: :add))
     |> assign_members()
     |> refresh_stages()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :section, section(params))
    socket = if socket.assigns.section == :keys, do: socket, else: assign(socket, :revealed, nil)
    {:noreply, socket}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{read_only?: true}} = socket) when event in ~w(
        save_board_name save_board_slug save_board_key edit_stage save_stage add_stage confirm_delete_stage
        toggle_wip bump_wip reorder_stage toggle_lane set_type set_reject_to
        toggle_collapsed_default invite_member remove_member flow_toggle
        flow_reset flow_confirm_reset flow_delete flow_confirm_delete
        flow_copy flow_copy_change flow_confirm_copy flow_add flow_add_change flow_confirm_add
        apply_shape_fix
        save_public_settings new_key create_key rename_key
        regenerate_key revoke_key
      ) do
    {:noreply, put_flash(socket, :error, "This board is archived (read-only).")}
  end

  def handle_event("new_key", _params, socket) do
    {:noreply, assign(socket, :new_key_form, new_key_form())}
  end

  def handle_event("cancel_new_key", _params, socket) do
    {:noreply, assign(socket, :new_key_form, nil)}
  end

  def handle_event("create_key", %{"new_key" => %{"name" => name}}, socket) do
    %{board: board, current_scope: scope} = socket.assigns

    case ApiKeys.create_key(board, scope.user, name) do
      {:ok, %{api_key: key, token: token}} ->
        {:noreply,
         socket
         |> assign(:new_key_form, nil)
         |> assign(:revealed, %{key_id: key.id, token: token})
         |> assign_keys(ApiKeys.list_keys(board))}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_key_form, to_form(changeset, as: :new_key))}
    end
  end

  # The key id travels as `key_id`, not `id`: a form input named `id` shadows the
  # form element's own `id` property, which LiveView's client relies on.
  def handle_event("rename_key", %{"key_id" => id, "api_key" => %{"name" => name}}, socket) do
    board = socket.assigns.board

    case board |> ApiKeys.get_key!(id) |> ApiKeys.rename(name) do
      {:ok, _key} ->
        {:noreply, socket |> assign_keys(ApiKeys.list_keys(board)) |> put_flash(:info, "Key renamed.")}

      {:error, %{data: key} = changeset} ->
        {:noreply, update(socket, :key_forms, &Map.put(&1, key.id, to_form(changeset, as: :api_key)))}
    end
  end

  def handle_event("cancel_rename_key", _params, socket) do
    {:noreply, assign_keys(socket, socket.assigns.api_keys)}
  end

  def handle_event("regenerate_key", %{"id" => id}, socket) do
    board = socket.assigns.board
    {:ok, %{api_key: key, token: token}} = board |> ApiKeys.get_key!(id) |> ApiKeys.regenerate()

    {:noreply,
     socket
     |> assign(:revealed, %{key_id: key.id, token: token})
     |> assign_keys(ApiKeys.list_keys(board))}
  end

  def handle_event("revoke_key", %{"id" => id}, socket) do
    board = socket.assigns.board
    {:ok, _key} = board |> ApiKeys.get_key!(id) |> ApiKeys.revoke()

    {:noreply,
     socket
     |> assign(:revealed, nil)
     |> assign_keys(ApiKeys.list_keys(board))
     |> put_flash(:info, "API key revoked.")}
  end

  def handle_event("save_public_settings", %{"board" => params}, socket) do
    attrs = %{
      "public_enabled" => params["public_enabled"] == "true",
      "public_intake_stage_id" => params["public_intake_stage_id"]
    }

    case Boards.update_public_settings(socket.assigns.board, attrs) do
      {:ok, board} ->
        {:noreply,
         socket
         |> assign(:board, board)
         |> assign(:public_form, to_form(Board.public_settings_changeset(board, %{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :public_form, to_form(changeset))}
    end
  end

  def handle_event("save_board_name", %{"board" => %{"name" => _} = params}, socket) do
    case Boards.update_board(socket.assigns.board, Map.take(params, ["name"])) do
      {:ok, board} ->
        {:noreply,
         socket
         |> assign(:board, board)
         |> assign(:general_form, to_form(Boards.change_board(board)))
         |> put_flash(:info, "Board name saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :general_form, to_form(changeset))}
    end
  end

  def handle_event("save_board_slug", %{"board" => %{"slug" => _} = params}, socket) do
    current = socket.assigns.board

    case Boards.update_board(current, Map.take(params, ["slug"])) do
      {:ok, %{slug: slug} = board} when slug == current.slug ->
        {:noreply,
         socket
         |> assign(:board, board)
         |> assign(:general_form, to_form(Boards.change_board(board)))}

      {:ok, board} ->
        {:noreply,
         socket
         |> put_flash(:info, "Board URL saved.")
         |> push_navigate(to: ~p"/board/#{board.slug}/settings?section=general")}

      {:error, changeset} ->
        {:noreply, assign(socket, :general_form, to_form(changeset))}
    end
  end

  def handle_event("cancel_board_name", _params, socket) do
    {:noreply, assign(socket, :general_form, to_form(Boards.change_board(socket.assigns.board)))}
  end

  def handle_event("cancel_board_slug", _params, socket) do
    {:noreply, assign(socket, :general_form, to_form(Boards.change_board(socket.assigns.board)))}
  end

  def handle_event("save_board_key", %{"board" => %{"key" => _} = params}, socket) do
    case Boards.update_board(socket.assigns.board, Map.take(params, ["key"])) do
      {:ok, board} ->
        {:noreply,
         socket
         |> assign(:board, board)
         |> assign(:general_form, to_form(Boards.change_board(board)))
         |> put_flash(:info, "Card key saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :general_form, to_form(changeset))}
    end
  end

  def handle_event("cancel_board_key", _params, socket) do
    {:noreply, assign(socket, :general_form, to_form(Boards.change_board(socket.assigns.board)))}
  end

  def handle_event("archive_board", _params, socket) do
    {:ok, _board} = Boards.archive_board(socket.assigns.board)

    {:noreply,
     socket
     |> put_flash(:info, "Board archived.")
     |> push_navigate(to: ~p"/boards")}
  end

  def handle_event("invite_member", %{"invite" => %{"email" => email}}, socket) do
    case Members.invite(socket.assigns.board, email) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> assign(:invite_form, to_form(%{"email" => ""}, as: :invite))
         |> assign_members()}

      {:error, :already_member} ->
        {:noreply, put_flash(socket, :error, "That person is already a member of this board.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Enter a valid email address.")}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    membership = Enum.find(socket.assigns.members, &(to_string(&1.id) == id))

    cond do
      is_nil(membership) ->
        {:noreply, socket}

      membership.user_id == socket.assigns.current_scope.user.id ->
        {:noreply, socket}

      true ->
        {:ok, _} = Members.remove(membership)
        {:noreply, assign_members(socket)}
    end
  end

  def handle_event("set_type", %{"stage-id" => stage_id, "type" => type}, socket)
      when type in ~w(queue work planning review done) do
    stage = find_stage(socket, stage_id)

    case Cards.update_stage(stage, %{type: String.to_existing_atom(type)}) do
      {:ok, _updated} -> {:noreply, refresh_stages(socket)}
      {:error, {:holds_flow, _} = reason} -> {:noreply, put_flash(socket, :error, Boards.stage_refusal_message(reason))}
    end
  end

  # RE344 — Boards.update_stage/2 refuses a target that isn't a main stage on this board; a
  # refused or unparseable target leaves the socket as it was instead of crashing the view.
  def handle_event("set_reject_to", %{"stage-id" => stage_id, "target-id" => target_id}, socket) do
    stage = find_stage(socket, stage_id)

    with {:ok, target} <- parse_target(target_id),
         {:ok, _stage} <- Boards.update_stage(stage, %{reject_to_stage_id: target}) do
      {:noreply, refresh_stages(socket)}
    else
      _refused -> {:noreply, socket}
    end
  end

  def handle_event("toggle_collapsed_default", %{"stage-id" => stage_id}, socket) do
    stage = find_stage(socket, stage_id)
    {:ok, _stage} = Boards.update_stage(stage, %{collapsed_by_default: not stage.collapsed_by_default})
    {:noreply, refresh_stages(socket)}
  end

  def handle_event("toggle_lane", %{"stage-id" => stage_id, "lane" => lane}, socket) do
    lane = lane_atom(lane)
    stage = find_stage(socket, stage_id)

    result =
      if lane_on?(socket.assigns.lane_map, stage.id, lane) do
        Boards.disable_lane(stage, lane)
      else
        Boards.enable_lane(stage, lane)
      end

    {:noreply, apply_lane_result(socket, result, stage.id, lane)}
  end

  def handle_event("edit_stage", %{"stage-id" => stage_id, "field" => field}, socket)
      when field in ~w(name description) do
    stage = find_stage(socket, stage_id)
    value = Map.get(stage, String.to_existing_atom(field))

    {:noreply,
     socket
     |> assign(:editing_stage, {stage.id, field})
     |> assign(:stage_form, to_form(%{field => value}, as: :stage))}
  end

  def handle_event("cancel_stage", _params, socket) do
    {:noreply, assign(socket, editing_stage: nil, stage_form: nil)}
  end

  def handle_event("save_stage", %{"stage_id" => stage_id, "stage" => stage_params}, socket) do
    stage = find_stage(socket, stage_id)
    attrs = Map.take(stage_params, ["name", "description"])

    case Boards.update_stage(stage, attrs) do
      {:ok, _stage} ->
        {:noreply,
         socket
         |> assign(editing_stage: nil, stage_form: nil)
         |> refresh_stages()}

      {:error, changeset} ->
        {:noreply, assign(socket, :stage_form, to_form(changeset))}
    end
  end

  # MMF 11 — the mockup's onToggleLimit (line ~1102): enabling defaults the
  # limit to 3, disabling clears it (nil = no limit, chip hidden, enforcement off).
  def handle_event("toggle_wip", %{"stage-id" => stage_id}, socket) do
    stage = find_stage(socket, stage_id)
    {:ok, _stage} = Boards.update_stage(stage, %{wip_limit: if(stage.wip_limit, do: nil, else: 3)})
    {:noreply, refresh_stages(socket)}
  end

  # MMF 11 — the mockup's bumpWip (line ~892): step by ±1, flooring at 1.
  def handle_event("bump_wip", %{"stage-id" => stage_id, "delta" => delta}, socket) when delta in ["1", "-1"] do
    stage = find_stage(socket, stage_id)
    limit = max(1, (stage.wip_limit || 1) + String.to_integer(delta))
    {:ok, _stage} = Boards.update_stage(stage, %{wip_limit: limit})
    {:noreply, refresh_stages(socket)}
  end

  def handle_event("reorder_stage", %{"stage-id" => stage_id, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    {:ok, _stage} = Boards.reorder_stage(find_stage(socket, stage_id), direction_atom(direction))
    {:noreply, refresh_stages(socket)}
  end

  def handle_event("add_stage", %{"category" => category}, socket)
      when category in ["unstarted", "planning", "in_progress", "complete"] do
    {:ok, _stage} = Boards.create_stage(socket.assigns.board, category_atom(category))
    {:noreply, refresh_stages(socket)}
  end

  # RE431 — the × opens the inline delete panel (it names the flow the stage takes with it);
  # nothing is written until `confirm_delete_stage`.
  def handle_event("delete_stage", %{"stage-id" => stage_id}, socket) do
    case find_stage(socket, stage_id) do
      nil -> {:noreply, socket}
      stage -> {:noreply, socket |> close_panel() |> assign(:panel, {stage.id, :delete_stage})}
    end
  end

  # A refusal stays inside the open panel rather than flashing. A stage already gone (deleted in
  # another tab) just closes the panel.
  def handle_event("confirm_delete_stage", %{"stage-id" => stage_id}, socket) do
    case find_stage(socket, stage_id) do
      nil ->
        {:noreply, socket |> close_panel() |> refresh_stages()}

      stage ->
        case Boards.delete_stage(stage) do
          {:ok, _stage} -> {:noreply, socket |> close_panel() |> refresh_stages()}
          {:error, reason} -> {:noreply, assign(socket, :panel_error, Boards.stage_refusal_message(reason))}
        end
    end
  end

  # RE432 — a one-click shape fix. The problem is re-read fresh, and the fix applied only when the
  # one at `index` still has the clicked `action`: the page may be stale (another tab already
  # fixed it), so a fix is never rebuilt from client params. Nothing to apply just refreshes.
  def handle_event("apply_shape_fix", %{"flow-key" => key, "index" => index, "action" => action}, socket) do
    board = socket.assigns.board

    case current_fix(board, key, index, action) do
      nil ->
        {:noreply, refresh_stages(socket)}

      fix ->
        shape_error =
          case Boards.apply_shape_fix(board, fix) do
            {:ok, _stage} -> nil
            {:error, reason} -> {key, shape_refusal(reason)}
          end

        {:noreply, socket |> assign(:shape_error, shape_error) |> refresh_stages()}
    end
  end

  # RE431 — the band's toggle flips the flow directly (the RLY-142 cutover confirm is gone).
  # RLY-182's readiness preflight survives as a report AFTER turning a flow on: computed here, on
  # the off→on click only, and opened as `{stage_id, :preflight}` only when some check warns. It
  # never blocks, and it is a snapshot — it does not live-update while open.
  def handle_event("flow_toggle", %{"flow-id" => flow_id}, socket) do
    case find_flow(socket, flow_id) do
      nil -> {:noreply, socket}
      flow -> {:noreply, toggle_flow(socket, flow)}
    end
  end

  def handle_event("flow_cancel_panel", _params, socket) do
    {:noreply, close_panel(socket)}
  end

  def handle_event("flow_reset", %{"flow-id" => flow_id}, socket) do
    {:noreply, open_flow_panel(socket, flow_id, :reset)}
  end

  def handle_event("flow_confirm_reset", %{"flow-id" => flow_id}, socket) do
    with_flow(socket, flow_id, fn flow ->
      case Flows.reset_to_default(flow) do
        {:ok, _flow} -> socket
        {:error, :not_a_default} -> put_flash(socket, :error, "Only flows from the default library can be reset.")
        {:error, changeset} -> put_flash(socket, :error, "Could not reset the flow: #{flow_errors(changeset)}.")
      end
    end)
  end

  def handle_event("flow_delete", %{"flow-id" => flow_id}, socket) do
    {:noreply, open_flow_panel(socket, flow_id, :delete_flow)}
  end

  def handle_event("flow_confirm_delete", %{"flow-id" => flow_id}, socket) do
    with_flow(socket, flow_id, fn flow ->
      case Flows.delete_flow(flow) do
        {:ok, _flow} -> socket
        {:error, :flow_enabled} -> put_flash(socket, :error, "Turn the flow off before deleting it.")
        {:error, changeset} -> put_flash(socket, :error, "Could not delete the flow: #{flow_errors(changeset)}.")
      end
    end)
  end

  # RE431 — Copy to another stage…: the picker is keyed by the SOURCE flow's stage and offers
  # only `@copy_targets` (`Flows.assignable_stages(board, nil)`, the one "free work stage" rule).
  def handle_event("flow_copy", %{"flow-id" => flow_id}, socket) do
    case {find_flow(socket, flow_id), socket.assigns.copy_targets} do
      {nil, _targets} ->
        {:noreply, socket}

      {_flow, []} ->
        {:noreply, socket}

      {flow, [first | _]} ->
        {:noreply,
         socket
         |> close_panel()
         |> assign(:panel, {flow.stage_id, :copy})
         |> assign_copy_form(flow, first.id)}
    end
  end

  def handle_event("flow_copy_change", %{"copy" => %{"stage_id" => stage_id}} = params, socket) do
    case find_flow(socket, params["flow_id"]) do
      nil -> {:noreply, socket}
      flow -> {:noreply, assign_copy_form(socket, flow, stage_id)}
    end
  end

  def handle_event("flow_confirm_copy", %{"flow_id" => flow_id, "copy" => %{"stage_id" => stage_id}}, socket) do
    case {find_flow(socket, flow_id), find_copy_target(socket, stage_id)} do
      {nil, _target} ->
        {:noreply, socket}

      {_flow, nil} ->
        {:noreply, put_flash(socket, :error, "Pick a stage without a flow.")}

      {flow, target} ->
        socket =
          case Flows.copy_flow(flow, target) do
            {:ok, _copy} -> socket
            {:error, changeset} -> put_flash(socket, :error, "Could not copy the flow: #{flow_errors(changeset)}.")
          end

        {:noreply, socket |> close_panel() |> refresh_stages()}
    end
  end

  # RE431 — + Add flow on a work stage with no flow: a default-library flow not yet on the board,
  # or a blank one. The panel renders inside that stage's no-flow band.
  def handle_event("flow_add", %{"stage-id" => stage_id}, socket) do
    case find_flow_free_stage(socket, stage_id) do
      nil ->
        {:noreply, socket}

      stage ->
        defaults = socket.assigns.addable_defaults
        source = if defaults == [], do: "blank", else: "default"

        {:noreply,
         socket
         |> close_panel()
         |> assign(:panel, {stage.id, :add})
         |> assign(:add_form, to_form(%{"source" => source, "default_key" => List.first(defaults)}, as: :add))}
    end
  end

  def handle_event("flow_add_change", %{"add" => params}, socket) do
    {:noreply, assign(socket, :add_form, to_form(Map.take(params, ["source", "default_key"]), as: :add))}
  end

  def handle_event("flow_confirm_add", %{"stage_id" => stage_id, "add" => params}, socket) do
    case find_flow_free_stage(socket, stage_id) do
      nil ->
        {:noreply, socket}

      stage ->
        socket =
          case Flows.add_flow(stage, add_source(params)) do
            {:ok, _flow} ->
              socket

            {:error, :not_a_default} ->
              put_flash(socket, :error, "That flow isn't in the default library.")

            {:error, changeset} ->
              put_flash(socket, :error, "Could not add the flow: #{flow_errors(changeset)}.")
          end

        {:noreply, socket |> close_panel() |> refresh_stages()}
    end
  end

  @impl true
  def handle_info({:member_removed, user_id}, socket) do
    if socket.assigns.current_scope.user.id == user_id do
      {:noreply,
       socket
       |> put_flash(:info, "You were removed from this board.")
       |> push_navigate(to: ~p"/boards")}
    else
      {:noreply, assign_members(socket)}
    end
  end

  # RE431: every stage row shows its flow and the neighbours worked out from board order, so
  # any stage change (rename, reorder, add, delete — or a flow change on it) re-reads both.
  def handle_info({:stages_changed, _board_id}, socket) do
    {:noreply, refresh_stages(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @doc """
  The display name of a settings section (RE334) — the ONE place it is written. The rail, the
  mobile tab strip, the top-bar title, the Runners page title and `RelayWeb.BoardCrumbs`'
  `Stages` crumb all call this, so a rename lands everywhere at once.
  """
  def section_label(:general), do: "General"
  def section_label(:stages), do: "Stages"
  def section_label(:public), do: "Public board"
  def section_label(:members), do: "Members"
  def section_label(:keys), do: "API keys"
  def section_label(:runners), do: "Runners"

  defp section(%{"section" => "public"}), do: :public
  defp section(%{"section" => "stages"}), do: :stages
  # RE431 — the Flows tab is gone; its old links land on Stages, where each row owns its flow.
  defp section(%{"section" => "flows"}), do: :stages
  defp section(%{"section" => "keys"}), do: :keys
  defp section(%{"section" => "members"}), do: :members
  defp section(_params), do: :general

  # Reloads the main stages, lane map and every row's flow from the DB after any mutation, and
  # groups them for the pane. All four categories always render so an emptied category keeps its
  # "+ Add stage" button. The one reload point — it leaves `@editing_stage`, `@panel` and
  # `@lane_nonce` alone, since it also runs on every `{:stages_changed, _}` (a panel whose stage
  # is gone is closed).
  defp refresh_stages(socket) do
    board = socket.assigns.board
    all_stages = Boards.list_stages(board)
    stage_rows = stage_rows(board)
    mains = Enum.filter(all_stages, &is_nil(&1.parent_id))

    groups =
      Enum.map(@categories, fn category ->
        {category, Enum.filter(mains, &(&1.category == category))}
      end)

    socket
    |> assign(:stages, mains)
    |> assign(:stage_groups, groups)
    |> assign(:lane_map, lane_map(board))
    |> assign(:all_stages, all_stages)
    |> assign(:neighbours, Map.new(mains, &{&1.id, neighbour_names(&1.id, all_stages)}))
    |> assign(:stage_rows, stage_rows)
    |> assign(:paused_stage_ids, paused_stage_ids(all_stages, stage_rows))
    |> assign(:copy_targets, Flows.assignable_stages(board, nil))
    |> assign(:addable_defaults, Flows.addable_defaults(board))
    |> drop_orphan_panel()
    |> drop_cleared_shape_error()
  end

  # The stages whose flow is paused (`Flows.paused?/1`), in board order — the summary links the first.
  defp paused_stage_ids(all_stages, stage_rows) do
    for %Stage{id: id} <- all_stages, row = stage_rows[id], Flows.paused?(row.flow), do: id
  end

  # A refusal stays only while its flow still has a problem (fixed elsewhere → it goes).
  defp drop_cleared_shape_error(%{assigns: %{shape_error: {key, _message}, stage_rows: rows}} = socket) do
    if Enum.any?(Map.values(rows), &(&1.flow.key == key and &1.flow.problem)),
      do: socket,
      else: assign(socket, :shape_error, nil)
  end

  defp drop_cleared_shape_error(socket), do: socket

  defp current_fix(board, key, index, action) do
    with %{fixes: fixes} <- Enum.find(Flows.shape_problems(board), &(&1.flow_key == key)),
         {i, ""} when i >= 0 <- Integer.parse(index),
         %{action: fix_action} = fix <- Enum.at(fixes, i),
         true <- Atom.to_string(fix_action) == action do
      fix
    else
      _stale -> nil
    end
  end

  defp shape_refusal(%Ecto.Changeset{} = changeset), do: Enum.join(ChangesetErrors.leaf_messages(changeset), "; ")
  defp shape_refusal(reason), do: Boards.stage_refusal_message(reason)

  defp row_problem(stage_rows, stage_id) do
    case stage_rows[stage_id] do
      %{flow: %{problem: problem}} -> problem
      nil -> nil
    end
  end

  defp shape_error_for({key, message}, key), do: message
  defp shape_error_for(_shape_error, _key), do: nil

  defp paused_count_label(1), do: "1 flow is paused"
  defp paused_count_label(n), do: "#{n} flows are paused"

  @stage_row_base "background:var(--color-base-100);border-radius:13px;padding:16px 18px;display:flex;flex-direction:column;gap:14px;"

  defp stage_row_style(true),
    do:
      @stage_row_base <>
        "border:2px solid color-mix(in oklab, var(--color-warning) 70%, var(--color-base-100));" <>
        "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-warning) 12%, transparent);"

  defp stage_row_style(false), do: @stage_row_base <> "border:1px solid var(--color-base-300);"

  # A panel stays open across a refresh — unless its stage is gone (deleted in another tab).
  defp drop_orphan_panel(%{assigns: %{panel: {stage_id, _kind}, stages: stages}} = socket) do
    if Enum.any?(stages, &(&1.id == stage_id)), do: socket, else: close_panel(socket)
  end

  defp drop_orphan_panel(socket), do: socket

  # One entry per stage that holds a flow (RE429: at most one each).
  defp stage_rows(board) do
    board
    |> Flows.list_flows()
    |> Map.new(fn flow ->
      customized? = Flows.customized?(flow)
      {flow.stage_id, %{flow: flow, customized?: customized?, resettable?: customized? and Flows.default_key?(flow.key)}}
    end)
  end

  # The pulls-from / lands-on rule is `Flows.neighbours/2`'s; a sub-lane neighbour renders as
  # `"Plan · Done"` through `Boards.stage_display_name/2`, never its stored `"Plan:Done"` name.
  defp neighbour_names(stage_id, all_stages) do
    stage_id
    |> Flows.neighbours(all_stages)
    |> Map.new(fn {side, stage} -> {side, display_name(stage, all_stages)} end)
  end

  defp display_name(nil, _all_stages), do: nil
  defp display_name(%Stage{parent_id: nil} = stage, _all_stages), do: Boards.stage_display_name(stage, stage)

  defp display_name(%Stage{parent_id: parent_id} = stage, all_stages),
    do: Boards.stage_display_name(stage, Enum.find(all_stages, &(&1.id == parent_id)))

  defp main_stages_for_intake(stages), do: Enum.filter(stages, &is_nil(&1.parent_id))

  defp intake_row_style(active?) do
    border =
      if active?,
        do: "color-mix(in oklab, var(--color-primary) 35%, var(--color-base-100))",
        else: "var(--color-base-300)"

    bg =
      if active?,
        do: "color-mix(in oklab, var(--color-primary) 10%, var(--color-base-100))",
        else: "var(--color-base-100)"

    "display:flex;align-items:center;gap:9px;padding:10px 12px;border-radius:9px;cursor:pointer;background:#{bg};border:1px solid #{border};"
  end

  # Ids in the DOM come from this user's own board rows.
  defp find_stage(socket, stage_id) do
    id = String.to_integer(stage_id)
    Enum.find(socket.assigns.stages, &(&1.id == id))
  end

  # Ids in the DOM come from this board's own stage rows; a foreign or malformed id resolves to
  # nil and the event is ignored rather than crashing the view.
  defp find_flow(socket, flow_id) do
    case Integer.parse(to_string(flow_id)) do
      {id, ""} -> Enum.find_value(Map.values(socket.assigns.stage_rows), &(&1.flow.id == id && &1.flow))
      _other -> nil
    end
  end

  # A copy target resolves ONLY from `@copy_targets`, so a foreign or occupied id is nil.
  defp find_copy_target(socket, stage_id) do
    case Integer.parse(to_string(stage_id)) do
      {id, ""} -> Enum.find(socket.assigns.copy_targets, &(&1.id == id))
      _other -> nil
    end
  end

  # The board's own main stage for `stage_id`; `Flows.add_flow/2` validates the rest.
  defp find_flow_free_stage(socket, stage_id) do
    case Integer.parse(to_string(stage_id)) do
      {id, ""} -> Enum.find(socket.assigns.stages, &(&1.id == id))
      _other -> nil
    end
  end

  defp assign_copy_form(socket, flow, stage_id) do
    target = find_copy_target(socket, stage_id)

    socket
    |> assign(:copy_form, to_form(%{"stage_id" => target && target.id}, as: :copy))
    |> assign(:copy_key, target && Flows.copy_key(flow, target))
  end

  defp add_source(%{"source" => "default"} = params), do: {:default, params["default_key"] || ""}
  defp add_source(_params), do: :blank

  # `@panel` is `{stage_id, kind}`; each row is handed only its own kind (or nil).
  defp panel_kind({stage_id, kind}, stage_id), do: kind
  defp panel_kind(_panel, _stage_id), do: nil

  defp open_flow_panel(socket, flow_id, kind) do
    case find_flow(socket, flow_id) do
      nil -> socket
      flow -> socket |> close_panel() |> assign(:panel, {flow.stage_id, kind})
    end
  end

  # The preflight snapshot and any refusal are bound to one open panel — they die with it.
  defp close_panel(socket) do
    assign(socket, panel: nil, flow_preflight: nil, panel_error: nil)
  end

  defp with_flow(socket, flow_id, fun) do
    case find_flow(socket, flow_id) do
      nil -> {:noreply, socket}
      flow -> {:noreply, flow |> fun.() |> close_panel() |> refresh_stages()}
    end
  end

  defp toggle_flow(socket, flow) do
    result = if flow.enabled, do: Flows.disable_flow(flow), else: Flows.enable_flow(flow)

    case result do
      {:ok, _flow} ->
        socket |> close_panel() |> refresh_stages() |> open_preflight(flow)

      {:error, changeset} ->
        put_flash(socket, :error, "Could not update the flow: #{flow_errors(changeset)}.")
    end
  end

  # `flow` is the pre-toggle struct: only an off→on flip gets a readiness report.
  defp open_preflight(socket, %{enabled: true}), do: socket

  defp open_preflight(socket, flow) do
    preflight = Runs.preflight_flow(flow)

    if FlowSettingsComponents.preflight_warns?(flow, preflight) do
      assign(socket, panel: {flow.stage_id, :preflight}, flow_preflight: preflight)
    else
      socket
    end
  end

  defp flow_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {_field, {message, _meta}} -> message end)
    |> Enum.uniq()
    |> Enum.join("; ")
  end

  defp assign_members(socket) do
    members = Members.list_members(socket.assigns.board)

    socket
    |> assign(:members, members)
    |> assign(:member_count, length(members))
  end

  defp mine?(%Membership{user_id: user_id}, scope), do: user_id == scope.user.id

  defp member_name(%Membership{user: %User{name: name}}) when is_binary(name) and name != "", do: name

  defp member_name(%Membership{email: email}), do: email |> String.split("@") |> hd()

  # The effective reject target id: the explicit reject_to, else the previous main stage.
  defp effective_reject_to(stage) do
    case stage.reject_to_stage_id do
      nil ->
        case Boards.previous_main_stage(stage) do
          %Stage{id: id} -> id
          nil -> nil
        end

      id ->
        id
    end
  end

  # Selectable reject targets: the board's other main stages, in position order.
  defp reject_route_options(stage, stages) do
    stages
    |> Enum.reject(&(&1.id == stage.id))
    |> Enum.sort_by(& &1.position)
  end

  defp reject_route_name(stage, stages) do
    case effective_reject_to(stage) do
      nil -> "Previous stage"
      id -> (Enum.find(stages, &(&1.id == id)) || %{name: "Previous stage"}).name
    end
  end

  defp parse_target(""), do: {:ok, nil}

  defp parse_target(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _other -> :error
    end
  end

  defp lane_atom(lane), do: Enum.find(Stage.sublane_types(), &(Atom.to_string(&1) == lane))

  defp direction_atom("up"), do: :up
  defp direction_atom("down"), do: :down

  defp category_atom("unstarted"), do: :unstarted
  defp category_atom("planning"), do: :planning
  defp category_atom("in_progress"), do: :in_progress
  defp category_atom("complete"), do: :complete

  # The disable was rejected server-side, so `lane_map` (and thus the
  # `checked` value the toggle renders) is unchanged — but the native
  # checkbox already flipped itself off the instant the user clicked it,
  # before the "blocked" reply came back. Because the rendered `checked`
  # output is identical to last render, LiveView sends no diff for that
  # node, so the stale client-side property would otherwise never get
  # corrected. Bumping the nonce changes the input's `id`, forcing the
  # client to swap in a freshly-parsed element (checked from the true
  # server state) instead of patching the one the user already toggled.
  defp apply_lane_result(socket, {:error, reason}, stage_id, lane) do
    socket
    |> put_flash(:error, Boards.stage_refusal_message(reason))
    |> update(:lane_nonce, &Map.update(&1, {stage_id, lane}, 1, fn n -> n + 1 end))
  end

  defp apply_lane_result(socket, {:ok, _}, _stage_id, _lane), do: refresh_stages(socket)

  defp toggle_id(lane_nonce, stage_id, lane) do
    case Map.get(lane_nonce, {stage_id, lane}, 0) do
      0 -> "stage-#{stage_id}-#{lane}-toggle"
      n -> "stage-#{stage_id}-#{lane}-toggle-#{n}"
    end
  end

  defp lane_map(board) do
    board
    |> Boards.list_stages()
    |> Enum.filter(&(not is_nil(&1.parent_id)))
    |> Enum.group_by(& &1.parent_id, & &1.type)
    |> Map.new(fn {parent_id, lanes} -> {parent_id, MapSet.new(lanes)} end)
  end

  defp lane_on?(lane_map, stage_id, lane), do: MapSet.member?(Map.get(lane_map, stage_id, MapSet.new()), lane)

  # The mockup's navItem style (line ~1114).
  defp nav_style(true) do
    "display:block;text-align:left;border:none;border-radius:8px;padding:8px 10px;" <>
      "font-size:13.5px;text-decoration:none;font-weight:600;" <>
      "background:color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100));color:color-mix(in oklab, var(--color-primary) 45%, var(--color-base-content));"
  end

  defp nav_style(false) do
    "display:block;text-align:left;border:none;border-radius:8px;padding:8px 10px;" <>
      "font-size:13.5px;text-decoration:none;font-weight:500;" <>
      "background:transparent;color:color-mix(in oklab, var(--color-base-content) 75%, transparent);"
  end

  # RLY-72: horizontal tab in the mobile settings strip. Reuses nav_style/1's
  # active/inactive blue-tint values (active = primary 15% tint background with
  # primary 45% ink text), laid out as a non-wrapping pill for a horizontal row.
  # No artboard — deliberate responsive design matching the settings chrome.
  defp tab_style(true) do
    "flex:0 0 auto;text-decoration:none;padding:10px 14px;border-radius:8px;" <>
      "font-size:13.5px;font-weight:600;white-space:nowrap;" <>
      "background:color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100));color:color-mix(in oklab, var(--color-primary) 45%, var(--color-base-content));"
  end

  defp tab_style(false) do
    "flex:0 0 auto;text-decoration:none;padding:10px 14px;border-radius:8px;" <>
      "font-size:13.5px;font-weight:500;white-space:nowrap;" <>
      "background:transparent;color:color-mix(in oklab, var(--color-base-content) 75%, transparent);"
  end

  # The mockup's limitToggleStyle (line ~1092): blue-tinted when On.
  defp wip_toggle_style(true) do
    "font-size:12px;font-weight:600;padding:5px 12px;border-radius:7px;" <>
      "border:1px solid color-mix(in oklab, var(--color-primary) 65%, var(--color-base-100));background:color-mix(in oklab, var(--color-primary) 10%, var(--color-base-100));color:color-mix(in oklab, var(--color-primary) 55%, var(--color-base-content));"
  end

  defp wip_toggle_style(false) do
    "font-size:12px;font-weight:600;padding:5px 12px;border-radius:7px;" <>
      "border:1px solid var(--color-field-border);background:var(--color-base-100);color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
  end

  defp type_label(:queue), do: "Queue"
  defp type_label(:work), do: "Work"
  defp type_label(:planning), do: "Planning"
  defp type_label(:review), do: "Review"
  defp type_label(:done), do: "Done"

  defp category_band_label(:unstarted), do: "UNSTARTED"
  defp category_band_label(:planning), do: "PLANNING"
  defp category_band_label(:in_progress), do: "IN PROGRESS"
  defp category_band_label(:complete), do: "COMPLETE"

  # Mirrors the board's category band dots (mockup catMeta, lines ~906-908).
  defp category_dot_style(:unstarted),
    do:
      "width:9px;height:9px;border-radius:50%;border:1.5px solid color-mix(in oklab, var(--color-base-content) 45%, var(--color-base-100));box-sizing:border-box;display:block;flex:0 0 auto;"

  defp category_dot_style(:planning),
    do:
      "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-secondary) 0 25%, color-mix(in oklab, var(--color-primary) 35%, var(--color-base-100)) 25% 100%);display:block;flex:0 0 auto;"

  defp category_dot_style(:in_progress),
    do:
      "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-primary) 0 50%, color-mix(in oklab, var(--color-primary) 35%, var(--color-base-100)) 50% 100%);display:block;flex:0 0 auto;"

  defp category_dot_style(:complete),
    do: "width:9px;height:9px;border-radius:50%;background:var(--color-success);display:block;flex:0 0 auto;"

  defp assign_keys(socket, keys) do
    socket
    |> assign(:api_keys, keys)
    |> assign(:key_forms, Map.new(keys, &{&1.id, key_form(&1)}))
  end

  defp key_form(key), do: to_form(ApiKey.name_changeset(key, %{}), as: :api_key)

  defp new_key_form, do: to_form(%{"name" => ""}, as: :new_key)

  defp masked(key), do: "relay_#{key.token_prefix}_…#{key.last_four}"

  defp last_used(%{last_used_at: nil}), do: "Never"
  defp last_used(%{last_used_at: at}), do: format_time(at)

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%b %d, %Y, %H:%M UTC")
end
