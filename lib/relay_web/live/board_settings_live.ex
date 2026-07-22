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
  valid status) and — for work/planning stages only — a violet AI-ENABLED
  toggle (`toggle_ai` event, "Relay AI listens here"). The old approval-gate
  toggle is gone: gating is now implicit in `type: :review`.

  RLY-57: a top-level review stage (`type: :review`, no `parent_id`) carries an
  "ON REJECT, SEND TO" dropdown (`set_reject_to` event) that persists
  `stage.reject_to_stage_id`; a review sub-lane always rejects back into its
  own parent stage and shows a fixed hint instead. When no `reject_to_stage_id`
  is set, the effective target falls back to `Boards.previous_main_stage/1`.
  """

  use RelayWeb, :live_view

  alias Relay.ApiKeys
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Relay.Flows
  alias Relay.Members
  alias Relay.Runs
  alias RelayWeb.FlowSettingsComponents
  alias Schemas.Board
  alias Schemas.Membership
  alias Schemas.Stage
  alias Schemas.User

  @categories [:unstarted, :planning, :in_progress, :complete]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide crumb>
      <:title>
        <span id="settings-title">Board settings</span>
      </:title>
      <:actions>
        <.link
          navigate={~p"/board/#{@board.slug}"}
          id="settings-done"
          class="btn btn-sm border-none font-semibold text-white"
          style="background:oklch(0.60 0.14 250);"
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
          style="border-bottom:1px solid oklch(0.93 0.006 255);background:oklch(0.992 0.002 255);padding:0 14px;gap:2px;"
        >
          <.link
            patch={~p"/board/#{@board.slug}/settings"}
            id="settings-tab-general"
            style={tab_style(@section == :general)}
          >
            General
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=stages"}
            id="settings-tab-stages"
            style={tab_style(@section == :stages)}
          >
            Stages
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=flows"}
            id="settings-tab-flows"
            style={tab_style(@section == :flows)}
          >
            Flows
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=members"}
            id="settings-tab-members"
            style={tab_style(@section == :members)}
          >
            Members
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=keys"}
            id="settings-tab-keys"
            style={tab_style(@section == :keys)}
          >
            API keys
          </.link>
          <.link
            navigate={~p"/board/#{@board.slug}/runners"}
            id="settings-tab-runners"
            style={tab_style(false)}
          >
            Runners
          </.link>
        </nav>

        <%!-- Left rail — mockup "Relay Board.dc.html" lines ~176-183 --%>
        <nav
          id="settings-rail"
          class="hidden drawer:flex"
          style="width:210px;flex:0 0 auto;border-right:1px solid oklch(0.93 0.006 255);background:oklch(0.992 0.002 255);padding:22px 14px;flex-direction:column;gap:3px;"
        >
          <div
            class="font-mono"
            style="font-size:10px;font-weight:600;letter-spacing:0.08em;color:oklch(0.60 0.02 255);padding:4px 10px 8px 10px;"
          >
            BOARD
          </div>
          <.link
            patch={~p"/board/#{@board.slug}/settings"}
            id="settings-nav-general"
            style={nav_style(@section == :general)}
          >
            General
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=stages"}
            id="settings-nav-stages"
            style={nav_style(@section == :stages)}
          >
            Stages
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=flows"}
            id="settings-nav-flows"
            style={nav_style(@section == :flows)}
          >
            Flows
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=members"}
            id="settings-nav-members"
            style={nav_style(@section == :members)}
          >
            Members
          </.link>
          <.link
            patch={~p"/board/#{@board.slug}/settings?section=keys"}
            id="settings-nav-keys"
            style={nav_style(@section == :keys)}
          >
            API keys
          </.link>

          <div
            class="font-mono"
            style="font-size:10px;font-weight:600;letter-spacing:0.08em;color:oklch(0.60 0.02 255);padding:18px 10px 8px 10px;"
          >
            ENGINE
          </div>
          <.link
            navigate={~p"/board/#{@board.slug}/runners"}
            id="settings-nav-runners"
            style={nav_style(false)}
          >
            Runners
          </.link>
        </nav>

        <%!-- Content pane — mockup lines ~186-187 --%>
        <div style="flex:1;overflow-y:auto;background:oklch(0.985 0.004 250);">
          <div style="max-width:760px;margin:0 auto;padding:34px 40px 84px 40px;">
            <section :if={@section == :general} id="general-pane">
              <h1 style="font-size:22px;font-weight:600;letter-spacing:-0.02em;margin:0 0 6px 0;color:oklch(0.26 0.02 255);">
                General
              </h1>
              <p style="font-size:14px;line-height:1.55;color:oklch(0.50 0.02 255);margin:0 0 18px 0;max-width:560px;">
                The board's display name and its URL slug (relay.app/&lt;slug&gt;).
              </p>
              <div style="display:flex;flex-direction:column;gap:22px;max-width:420px;">
                <div>
                  <label style="font-size:12px;font-weight:600;color:oklch(0.40 0.02 255);">
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
                  <label style="font-size:12px;font-weight:600;color:oklch(0.40 0.02 255);">
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
              </div>

              <div
                :if={!@read_only?}
                id="danger-zone"
                style="margin-top:44px;border:1px solid oklch(0.90 0.03 15);border-radius:12px;padding:18px 20px;background:oklch(0.995 0.005 15);max-width:560px;"
              >
                <div style="font-size:13px;font-weight:600;color:oklch(0.45 0.14 15);margin-bottom:4px;">
                  Danger zone
                </div>
                <div style="display:flex;align-items:center;gap:16px;">
                  <span style="font-size:13px;color:oklch(0.50 0.04 15);flex:1;">
                    Archiving hides this board for everyone. You can restore it later.
                  </span>
                  <button
                    type="button"
                    id="archive-board-button"
                    phx-click="archive_board"
                    data-confirm="Archive this board?"
                    style="background:oklch(0.98 0.015 15);border:1px solid oklch(0.86 0.06 15);color:oklch(0.52 0.16 15);border-radius:8px;padding:8px 14px;font-size:13px;font-weight:600;cursor:pointer;"
                  >
                    Archive board
                  </button>
                </div>
              </div>
            </section>

            <section :if={@section == :stages} id="stages-pane">
              <h1 style="font-size:22px;font-weight:600;letter-spacing:-0.02em;margin:0 0 6px 0;color:oklch(0.26 0.02 255);">
                Stages
              </h1>
              <%!-- Mockup line ~217. --%>
              <p style="font-size:14px;line-height:1.55;color:oklch(0.50 0.02 255);margin:0 0 12px 0;max-width:560px;">
                Stages live inside four categories — <b style="color:oklch(0.34 0.02 255);">Unstarted</b>, <b style="color:oklch(0.34 0.02 255);">Planning</b>, <b style="color:oklch(0.34 0.02 255);">In progress</b>, and
                <b style="color:oklch(0.34 0.02 255);">Complete</b>
                — so everyone knows what a stage <i>means</i>. Use the arrows to move a stage
                up or down — cross into another category and it takes on that meaning. Set
                whether each stage is AI-enabled, its WIP limit, and whether it has Review and Done lanes.
              </p>

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
                    style="font-size:10.5px;font-weight:600;letter-spacing:0.09em;color:oklch(0.50 0.02 255);"
                  >
                    {category_band_label(category)}
                  </span>
                  <span class="font-mono" style="font-size:10.5px;color:oklch(0.68 0.02 255);">
                    {length(stages)}
                  </span>
                </div>
                <div style="display:flex;flex-direction:column;gap:12px;">
                  <div
                    :for={stage <- stages}
                    id={"stage-#{stage.id}-row"}
                    style="background:oklch(1 0 0);border:1px solid oklch(0.92 0.006 255);border-radius:13px;padding:16px 18px;display:flex;flex-direction:column;gap:14px;"
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
                          style="width:26px;height:26px;border-radius:6px;border:1px solid oklch(0.91 0.006 255);background:oklch(1 0 0);color:oklch(0.50 0.02 255);font-size:12px;padding:0;"
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
                          style="width:26px;height:26px;border-radius:6px;border:1px solid oklch(0.91 0.006 255);background:oklch(1 0 0);color:oklch(0.50 0.02 255);font-size:12px;padding:0;"
                        >
                          ↓
                        </button>
                        <button
                          type="button"
                          id={"stage-#{stage.id}-delete"}
                          phx-click="delete_stage"
                          phx-value-stage-id={stage.id}
                          data-confirm="Delete this stage?"
                          title="Delete stage"
                          style="width:26px;height:26px;border-radius:6px;border:1px solid oklch(0.90 0.03 15);background:oklch(0.98 0.015 15);color:oklch(0.55 0.14 15);font-size:14px;padding:0;margin-left:4px;"
                        >
                          ×
                        </button>
                      </div>
                    </div>
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
                    <%!-- TYPE dropdown + AI-ENABLED toggle (RLY-46). --%>
                    <div style="display:flex;align-items:center;gap:20px;flex-wrap:wrap;">
                      <div style="display:flex;align-items:center;gap:9px;">
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
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
                      <div
                        :if={stage.type in [:work, :planning]}
                        style="display:flex;align-items:center;gap:9px;"
                      >
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
                          AI-ENABLED
                        </span>
                        <input
                          id={"stage-#{stage.id}-ai-toggle"}
                          type="checkbox"
                          class="toggle toggle-sm toggle-secondary"
                          checked={stage.ai_enabled}
                          phx-click="toggle_ai"
                          phx-value-stage-id={stage.id}
                        />
                        <span
                          :if={stage.ai_enabled}
                          id={"stage-#{stage.id}-ai-hint"}
                          style="display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;letter-spacing:0.03em;color:oklch(0.46 0.14 292);"
                        >
                          <span style="width:11px;height:11px;border-radius:50%;background:oklch(0.56 0.16 292);display:flex;align-items:center;justify-content:center;">
                            <span style="width:4px;height:4px;border-radius:50%;border:1px solid oklch(1 0 0);">
                            </span>
                          </span>
                          Relay AI listens here
                        </span>
                      </div>
                      <%!-- COLLAPSED toggle (RLY-111) — board-wide default-collapse; any stage type. --%>
                      <div style="display:flex;align-items:center;gap:9px;">
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
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
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
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
                          style="display:inline-flex;align-items:center;border:1px solid oklch(0.90 0.006 255);border-radius:8px;overflow:hidden;"
                        >
                          <button
                            type="button"
                            id={"stage-#{stage.id}-wip-down"}
                            phx-click="bump_wip"
                            phx-value-stage-id={stage.id}
                            phx-value-delta="-1"
                            aria-label="Decrease WIP limit"
                            style="width:26px;height:30px;border:none;background:oklch(0.98 0.002 255);color:oklch(0.50 0.02 255);font-size:15px;padding:0;"
                          >
                            −
                          </button>
                          <span
                            id={"stage-#{stage.id}-wip-value"}
                            class="font-mono"
                            style="width:32px;text-align:center;font-size:13px;color:oklch(0.30 0.02 255);"
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
                            style="width:26px;height:30px;border:none;background:oklch(0.98 0.002 255);color:oklch(0.50 0.02 255);font-size:15px;padding:0;"
                          >
                            +
                          </button>
                        </div>
                      </div>
                    </div>
                    <div
                      :if={stage.type == :review and is_nil(stage.parent_id)}
                      style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;border-top:1px dashed oklch(0.94 0.006 255);padding-top:12px;"
                    >
                      <span class="font-mono" style="font-size:11px;color:oklch(0.44 0.11 195);">
                        ON REJECT, SEND TO
                      </span>
                      <details class="dropdown" id={"stage-#{stage.id}-reject-route"}>
                        <summary
                          class="btn btn-sm btn-outline gap-2"
                          style="color:oklch(0.34 0.09 205);border-color:oklch(0.86 0.06 195);"
                        >
                          <span style="width:7px;height:7px;border-radius:2px;background:oklch(0.55 0.11 195);">
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
                      <span style="flex:1;min-width:180px;font-size:11px;line-height:1.4;color:oklch(0.55 0.02 255);">
                        Rejected cards return here to be re-planned — the reviewer doesn't choose a destination.
                      </span>
                    </div>
                    <div
                      id={"stage-#{stage.id}-sublanes"}
                      style="display:flex;align-items:center;gap:24px;flex-wrap:wrap;border-top:1px dashed oklch(0.94 0.006 255);padding-top:12px;"
                    >
                      <div style="display:flex;align-items:center;gap:10px;">
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
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
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
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
                      <span style="flex:1;min-width:180px;font-size:11px;line-height:1.4;color:oklch(0.55 0.02 255);">
                        Both are optional lanes at the end of a stage —
                        <b style="color:oklch(0.40 0.02 255);">Review</b>
                        holds finished work for a human to approve or reject;
                        <b style="color:oklch(0.40 0.02 255);">Done</b>
                        parks it, ready for the next stage to pull.
                      </span>
                    </div>
                    <span
                      :if={lane_on?(@lane_map, stage.id, :review)}
                      style="font-size:11px;line-height:1.4;color:oklch(0.55 0.02 255);"
                    >
                      A review sub-lane always rejects back into its own stage — nothing to configure.
                    </span>
                  </div>
                </div>
                <button
                  type="button"
                  id={"add-stage-#{category}"}
                  phx-click="add_stage"
                  phx-value-category={category}
                  style="margin-top:10px;width:100%;border:1px dashed oklch(0.86 0.01 255);background:oklch(1 0 0);color:oklch(0.48 0.02 255);border-radius:11px;padding:11px;font-size:12.5px;font-weight:600;"
                >
                  + Add stage to {category_band_label(category)}
                </button>
              </div>
            </section>

            <FlowSettingsComponents.flows_pane
              :if={@section == :flows}
              rows={@flow_rows}
              panel={@flow_panel}
              preflight={@flow_preflight}
              slug={@board.slug}
              stages={@flow_stages}
              read_only?={@read_only?}
            />

            <section :if={@section == :members} id="members-pane">
              <h1 style="font-size:22px;font-weight:600;letter-spacing:-0.02em;margin:0 0 4px 0;color:oklch(0.24 0.02 255);">
                Members
              </h1>
              <p style="font-size:14px;color:oklch(0.52 0.02 255);margin:0 0 26px 0;">
                People with access to this board — and the AI agent that works alongside them.
              </p>

              <.form
                :let={f}
                for={@invite_form}
                id="invite-member-form"
                as={:invite}
                phx-submit="invite_member"
                style="background:oklch(1 0 0);border:1px solid oklch(0.92 0.006 255);border-radius:12px;padding:16px;display:flex;align-items:center;gap:10px;margin-bottom:26px;flex-wrap:wrap;"
              >
                <input
                  type="email"
                  id="invite-email"
                  name={f[:email].name}
                  value={Phoenix.HTML.Form.normalize_value("email", f[:email].value)}
                  placeholder="name@company.com"
                  autocomplete="off"
                  style="flex:1;min-width:180px;border:1px solid oklch(0.90 0.006 255);border-radius:8px;padding:9px 11px;font-size:13.5px;color:oklch(0.28 0.02 255);background:oklch(0.99 0.002 255);outline:none;"
                />
                <button
                  type="submit"
                  id="send-invite"
                  style="background:oklch(0.60 0.14 250);color:oklch(1 0 0);border:none;border-radius:8px;padding:9px 16px;font-size:13.5px;font-weight:600;"
                >
                  Send invite
                </button>
              </.form>

              <div
                class="font-mono"
                style="font-size:10px;font-weight:600;letter-spacing:0.08em;color:oklch(0.58 0.02 255);margin-bottom:10px;"
              >
                PEOPLE · {@member_count}
              </div>
              <div style="background:oklch(1 0 0);border:1px solid oklch(0.92 0.006 255);border-radius:12px;overflow:hidden;margin-bottom:28px;">
                <div
                  :for={m <- @members}
                  id={"member-row-#{m.id}"}
                  style="display:flex;align-items:center;gap:12px;padding:13px 16px;border-top:1px solid oklch(0.95 0.006 255);"
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
                      <span style="font-size:14px;font-weight:600;color:oklch(0.28 0.02 255);">
                        {member_name(m)}
                      </span>
                      <span
                        :if={mine?(m, @current_scope)}
                        class="font-mono"
                        style="font-size:10px;font-weight:600;letter-spacing:0.04em;background:oklch(0.95 0.03 250);color:oklch(0.45 0.13 250);padding:2px 6px;border-radius:5px;"
                      >
                        YOU
                      </span>
                      <span
                        :if={is_nil(m.user_id)}
                        class="font-mono"
                        style="font-size:10px;font-weight:600;letter-spacing:0.04em;background:oklch(0.96 0.03 75);color:oklch(0.52 0.11 65);padding:2px 6px;border-radius:5px;"
                      >
                        INVITED
                      </span>
                    </div>
                    <span class="font-mono" style="font-size:12.5px;color:oklch(0.56 0.02 255);">
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
                    style="width:28px;height:28px;border-radius:7px;border:1px solid oklch(0.92 0.006 255);background:oklch(1 0 0);color:oklch(0.55 0.02 255);font-size:15px;line-height:1;padding:0;flex:0 0 auto;"
                  >
                    ×
                  </button>
                  <span :if={mine?(m, @current_scope)} style="width:28px;flex:0 0 auto;"></span>
                </div>
              </div>

              <div
                class="font-mono"
                style="font-size:10px;font-weight:600;letter-spacing:0.08em;color:oklch(0.58 0.02 255);margin-bottom:10px;"
              >
                AGENT
              </div>
              <div
                id="agent-card"
                style="background:oklch(0.99 0.008 292);border:1px solid oklch(0.91 0.03 292);border-radius:12px;padding:16px;display:flex;align-items:center;gap:13px;"
              >
                <div style="width:38px;height:38px;border-radius:50%;background:oklch(0.56 0.16 292);display:flex;align-items:center;justify-content:center;flex:0 0 auto;">
                  <span style="width:14px;height:14px;border-radius:50%;border:2px solid oklch(1 0 0);">
                  </span>
                </div>
                <div style="flex:1;min-width:0;">
                  <div style="font-size:14px;font-weight:600;color:oklch(0.28 0.02 255);">
                    Relay AI
                  </div>
                  <div style="font-size:12.5px;color:oklch(0.50 0.03 292);">
                    Runs the AI-owned stages · authenticated with an API key
                  </div>
                </div>
                <.link
                  patch={~p"/board/#{@board.slug}/settings?section=keys"}
                  id="agent-manage-key"
                  style="background:oklch(1 0 0);border:1px solid oklch(0.88 0.03 292);color:oklch(0.46 0.13 292);border-radius:8px;padding:8px 14px;font-size:13px;font-weight:600;flex:0 0 auto;text-decoration:none;"
                >
                  Manage key →
                </.link>
              </div>
            </section>

            <section :if={@section == :keys} id="api-key-pane">
              <h1 style="font-size:22px;font-weight:600;letter-spacing:-0.02em;margin:0 0 4px 0;color:oklch(0.24 0.02 255);">
                API keys
              </h1>
              <p style="font-size:14px;line-height:1.55;color:oklch(0.52 0.02 255);margin:0 0 24px 0;max-width:520px;">
                Give a key to your agent so it can read the board, move cards, post progress, and
                ask questions on the AI-owned stages. Treat it like a password.
              </p>

              <div style="display:flex;align-items:center;gap:11px;background:oklch(0.99 0.008 292);border:1px solid oklch(0.91 0.03 292);border-radius:10px;padding:12px 14px;margin-bottom:22px;">
                <div style="width:26px;height:26px;border-radius:50%;background:oklch(0.56 0.16 292);display:flex;align-items:center;justify-content:center;flex:0 0 auto;">
                  <span style="width:10px;height:10px;border-radius:50%;border:1.5px solid oklch(1 0 0);">
                  </span>
                </div>
                <span style="font-size:13px;color:oklch(0.44 0.06 292);">
                  These keys authenticate <b>Relay AI</b> on this board.
                </span>
              </div>

              <div :if={@revealed_token} id="api-key-reveal" style="margin-bottom:14px;">
                <div
                  id="api-key-reveal-note"
                  class="font-mono"
                  style="font-size:11.5px;color:oklch(0.52 0.11 65);margin-bottom:6px;"
                >
                  Copy this key now — you won't be able to see it again.
                </div>
                <div style="display:flex;align-items:center;gap:8px;background:oklch(0.985 0.004 255);border:1px solid oklch(0.93 0.006 255);border-radius:9px;padding:10px 12px;">
                  <code
                    id="api-key-secret"
                    class="font-mono"
                    style="flex:1;min-width:0;font-size:13px;color:oklch(0.34 0.02 255);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
                  >
                    {@revealed_token}
                  </code>
                  <button
                    id="copy-key"
                    type="button"
                    phx-hook=".CopyKey"
                    data-target="api-key-secret"
                    style="background:oklch(0.97 0.004 255);border:1px solid oklch(0.91 0.006 255);color:oklch(0.42 0.02 255);border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;flex:0 0 auto;"
                  >
                    Copy
                  </button>
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
                          this.el.style.background = "oklch(0.95 0.06 150)"
                          this.el.style.borderColor = "oklch(0.80 0.10 150)"
                          this.el.style.color = "oklch(0.42 0.14 150)"
                          clearTimeout(this._t)
                          this._t = setTimeout(() => {
                            this.el.textContent = label
                            this.el.style.background = "oklch(0.97 0.004 255)"
                            this.el.style.borderColor = "oklch(0.91 0.006 255)"
                            this.el.style.color = "oklch(0.42 0.02 255)"
                          }, 1600)
                        })
                      }
                    }
                  </script>
                </div>
              </div>

              <div style="display:flex;flex-direction:column;gap:12px;">
                <div
                  :if={@api_key}
                  id="api-key-details"
                  style="background:oklch(1 0 0);border:1px solid oklch(0.92 0.006 255);border-radius:12px;padding:16px 18px;display:flex;flex-direction:column;gap:12px;"
                >
                  <div style="display:flex;align-items:center;gap:10px;">
                    <span
                      id="api-key-name"
                      style="font-size:14px;font-weight:600;color:oklch(0.28 0.02 255);flex:1;"
                    >
                      {@api_key.name}
                    </span>
                    <button
                      id="regenerate-key"
                      type="button"
                      phx-click="regenerate_key"
                      data-confirm="Regenerate the key? The current key stops working immediately."
                      style="background:transparent;border:1px solid oklch(0.91 0.006 255);color:oklch(0.48 0.02 255);border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;"
                    >
                      Regenerate
                    </button>
                    <button
                      id="revoke-key"
                      type="button"
                      phx-click="revoke_key"
                      data-confirm="Revoke the key? Tools using it will lose access."
                      style="background:oklch(0.98 0.015 15);border:1px solid oklch(0.90 0.04 15);color:oklch(0.52 0.16 15);border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;"
                    >
                      Revoke
                    </button>
                  </div>
                  <div style="display:flex;align-items:center;gap:8px;background:oklch(0.985 0.004 255);border:1px solid oklch(0.93 0.006 255);border-radius:9px;padding:10px 12px;">
                    <span
                      id="api-key-masked"
                      class="font-mono"
                      style="flex:1;min-width:0;font-size:13px;color:oklch(0.34 0.02 255);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
                    >
                      {masked(@api_key)}
                    </span>
                  </div>
                  <div class="font-mono" style="font-size:11.5px;color:oklch(0.60 0.02 255);">
                    <span id="api-key-created">Created {format_time(@api_key.inserted_at)}</span>
                    · <span id="api-key-last-used">last used {last_used(@api_key)}</span>
                  </div>
                </div>

                <button
                  :if={!@api_key}
                  id="generate-key"
                  type="button"
                  phx-click="generate_key"
                  style="border:1px dashed oklch(0.86 0.01 255);background:oklch(1 0 0);color:oklch(0.46 0.02 255);border-radius:11px;padding:11px 16px;font-size:13px;font-weight:600;"
                >
                  + Create new key
                </button>
              </div>

              <div style="margin-top:26px;font-size:12.5px;line-height:1.55;color:oklch(0.58 0.02 255);">
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
     |> assign(:api_key, ApiKeys.get_key(board))
     |> assign(:revealed_token, nil)
     |> assign(:lane_nonce, %{})
     |> assign(:general_form, to_form(Boards.change_board(board)))
     |> assign(:read_only?, Board.archived?(board))
     |> assign(:editing_stage, nil)
     |> assign(:stage_form, nil)
     |> assign(:invite_form, to_form(%{"email" => ""}, as: :invite))
     |> assign(:flow_rows, [])
     |> assign(:flow_stages, [])
     |> assign(:flow_panel, nil)
     |> assign(:flow_preflight, nil)
     |> assign_members()
     |> refresh_stages()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :section, section(params))
    socket = if socket.assigns.section == :flows, do: assign_flows(socket), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_event("generate_key", _params, socket) do
    case ApiKeys.create_key(socket.assigns.board, socket.assigns.current_scope.user) do
      {:ok, %{api_key: key, token: token}} ->
        {:noreply, socket |> assign(:api_key, key) |> assign(:revealed_token, token)}

      {:error, :already_exists} ->
        {:noreply,
         socket
         |> put_flash(:error, "This board already has an API key.")
         |> assign(:api_key, ApiKeys.get_key(socket.assigns.board))}
    end
  end

  def handle_event("regenerate_key", _params, socket) do
    {:ok, %{api_key: key, token: token}} = ApiKeys.regenerate(socket.assigns.api_key)
    {:noreply, socket |> assign(:api_key, key) |> assign(:revealed_token, token)}
  end

  def handle_event("revoke_key", _params, socket) do
    {:ok, _key} = ApiKeys.revoke(socket.assigns.api_key)

    {:noreply,
     socket
     |> assign(:api_key, nil)
     |> assign(:revealed_token, nil)
     |> put_flash(:info, "API key revoked.")}
  end

  def handle_event(event, _params, %{assigns: %{read_only?: true}} = socket) when event in ~w(
        save_board_name save_board_slug edit_stage save_stage add_stage delete_stage
        toggle_wip bump_wip reorder_stage toggle_lane set_type toggle_ai set_reject_to
        toggle_collapsed_default invite_member remove_member flow_toggle flow_confirm_toggle
        flow_duplicate flow_reset flow_confirm_reset flow_delete flow_confirm_delete
        flow_new flow_create_validate flow_create
      ) do
    {:noreply, put_flash(socket, :error, "This board is archived (read-only).")}
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
    {:ok, updated} = Boards.update_stage(stage, %{type: String.to_existing_atom(type)})
    :ok = Cards.snap_cards_in(updated)
    {:noreply, refresh_stages(socket)}
  end

  def handle_event("set_reject_to", %{"stage-id" => stage_id, "target-id" => target_id}, socket) do
    stage = find_stage(socket, stage_id)
    {:ok, _stage} = Boards.update_stage(stage, %{reject_to_stage_id: parse_target(target_id)})
    {:noreply, refresh_stages(socket)}
  end

  def handle_event("toggle_ai", %{"stage-id" => stage_id}, socket) do
    stage = find_stage(socket, stage_id)
    {:ok, _stage} = Boards.update_stage(stage, %{ai_enabled: not stage.ai_enabled})
    {:noreply, refresh_stages(socket)}
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

  def handle_event("delete_stage", %{"stage-id" => stage_id}, socket) do
    case Boards.delete_stage(find_stage(socket, stage_id)) do
      {:ok, _stage} ->
        {:noreply, refresh_stages(socket)}

      {:error, :not_empty} ->
        {:noreply, put_flash(socket, :error, "That stage still has cards — move them out first.")}

      {:error, :last_stage} ->
        {:noreply, put_flash(socket, :error, "A board needs at least one stage.")}
    end
  end

  # RLY-142 — the toggle never flips directly: it opens the inline cutover
  # confirm; only the confirm CTA persists.
  # RLY-182 — and the confirm carries a readiness preflight, computed HERE: on click, in
  # the enable direction only. Disabling needs no readiness check, and computing on every
  # render would cost a query per page load for an answer nobody asked for. It is a
  # snapshot — it does not live-update while the banner is open.
  def handle_event("flow_toggle", %{"flow-id" => flow_id}, socket) do
    flow = find_flow(socket, flow_id)
    preflight = if flow.enabled, do: nil, else: Runs.preflight_flow(flow)

    {:noreply,
     socket
     |> assign(:flow_panel, {flow.id, :confirm})
     |> assign(:flow_preflight, preflight)}
  end

  def handle_event("flow_cancel_panel", _params, socket) do
    {:noreply, close_flow_panel(socket)}
  end

  def handle_event("flow_confirm_toggle", %{"flow-id" => flow_id}, socket) do
    flow = find_flow(socket, flow_id)
    result = if flow.enabled, do: Flows.disable_flow(flow), else: Flows.enable_flow(flow)

    socket =
      case result do
        {:ok, _flow} -> socket
        {:error, changeset} -> put_flash(socket, :error, "Could not update the flow: #{flow_errors(changeset)}.")
      end

    {:noreply, socket |> close_flow_panel() |> assign_flows()}
  end

  def handle_event("flow_duplicate", %{"flow-id" => flow_id}, socket) do
    socket =
      case Flows.duplicate_flow(find_flow(socket, flow_id)) do
        {:ok, _copy} -> socket
        {:error, changeset} -> put_flash(socket, :error, "Could not duplicate the flow: #{flow_errors(changeset)}.")
      end

    {:noreply, socket |> close_flow_panel() |> assign_flows()}
  end

  def handle_event("flow_reset", %{"flow-id" => flow_id}, socket) do
    {:noreply, socket |> assign(:flow_panel, {parse_flow_id(flow_id), :reset}) |> assign(:flow_preflight, nil)}
  end

  def handle_event("flow_confirm_reset", %{"flow-id" => flow_id}, socket) do
    socket =
      case Flows.reset_to_default(find_flow(socket, flow_id)) do
        {:ok, _flow} -> socket
        {:error, :not_a_default} -> put_flash(socket, :error, "Only flows from the default library can be reset.")
        {:error, changeset} -> put_flash(socket, :error, "Could not reset the flow: #{flow_errors(changeset)}.")
      end

    {:noreply, socket |> close_flow_panel() |> assign_flows()}
  end

  def handle_event("flow_delete", %{"flow-id" => flow_id}, socket) do
    {:noreply, socket |> assign(:flow_panel, {parse_flow_id(flow_id), :delete}) |> assign(:flow_preflight, nil)}
  end

  def handle_event("flow_confirm_delete", %{"flow-id" => flow_id}, socket) do
    socket =
      case Flows.delete_flow(find_flow(socket, flow_id)) do
        {:ok, _flow} -> socket
        {:error, :flow_enabled} -> put_flash(socket, :error, "Disable the flow before deleting it.")
        {:error, changeset} -> put_flash(socket, :error, "Could not delete the flow: #{flow_errors(changeset)}.")
      end

    {:noreply, socket |> close_flow_panel() |> assign_flows()}
  end

  # RLY-158 — create from scratch. The panel is a {:new, form} variant of @flow_panel
  # rendered above the table, so it works on a board with no flows at all. Cancel reuses
  # the shared "flow_cancel_panel" event.
  def handle_event("flow_new", _params, socket) do
    form = new_flow_form(%{"key" => Flows.unique_key(socket.assigns.board, "new-flow")})
    {:noreply, socket |> assign(:flow_panel, {:new, form}) |> assign(:flow_preflight, nil)}
  end

  def handle_event("flow_create_validate", %{"flow" => params}, socket) do
    {:noreply, assign(socket, :flow_panel, {:new, new_flow_form(params)})}
  end

  def handle_event("flow_create", %{"flow" => params}, socket) do
    board = socket.assigns.board

    case create_new_flow(board, params) do
      {:ok, flow} ->
        {:noreply, push_navigate(socket, to: ~p"/board/#{board.slug}/flows/#{flow.key}")}

      {:error, errors} ->
        {:noreply, assign(socket, :flow_panel, {:new, new_flow_form(params, errors)})}
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

  # RLY-142: trigger chips render stage names, so track renames/deletes live
  # while the Flows section is open.
  def handle_info({:stages_changed, _board_id}, socket) do
    if socket.assigns.section == :flows do
      {:noreply, assign_flows(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp section(%{"section" => "stages"}), do: :stages
  defp section(%{"section" => "flows"}), do: :flows
  defp section(%{"section" => "keys"}), do: :keys
  defp section(%{"section" => "members"}), do: :members
  defp section(_params), do: :general

  # Reloads the main stages and lane map from the DB after any mutation, and
  # groups them for the pane. All four categories always render so an
  # emptied category keeps its "+ Add stage" button.
  defp refresh_stages(socket) do
    board = socket.assigns.board
    mains = board |> Boards.list_stages() |> Enum.filter(&is_nil(&1.parent_id))

    groups =
      Enum.map(@categories, fn category ->
        {category, Enum.filter(mains, &(&1.category == category))}
      end)

    socket
    |> assign(:stages, mains)
    |> assign(:stage_groups, groups)
    |> assign(:lane_map, lane_map(board))
  end

  # Ids in the DOM come from this user's own board rows.
  defp find_stage(socket, stage_id) do
    id = String.to_integer(stage_id)
    Enum.find(socket.assigns.stages, &(&1.id == id))
  end

  defp assign_flows(socket) do
    board = socket.assigns.board

    rows =
      board
      |> Flows.list_flows()
      |> Enum.map(fn flow ->
        customized? = Flows.customized?(flow)
        %{flow: flow, customized?: customized?, resettable?: customized? and Flows.default_key?(flow.key)}
      end)

    socket
    |> assign(:flow_rows, rows)
    |> assign(:flow_stages, Boards.list_stages(board))
  end

  # Ids in the DOM come from this board's own flow rows.
  defp find_flow(socket, flow_id) do
    id = parse_flow_id(flow_id)
    Enum.find(socket.assigns.flow_rows, &(&1.flow.id == id)).flow
  end

  defp parse_flow_id(flow_id), do: String.to_integer(flow_id)

  # The preflight is a snapshot bound to one open confirm — it dies with the panel.
  defp close_flow_panel(socket) do
    socket |> assign(:flow_panel, nil) |> assign(:flow_preflight, nil)
  end

  defp flow_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {_field, {message, _meta}} -> message end)
    |> Enum.uniq()
    |> Enum.join("; ")
  end

  @new_flow_trigger_fields [:pulls_from_stage_id, :works_in_stage_id, :lands_on_stage_id]

  # The all-three-triggers-required rule is a *form* rule, not a context rule:
  # create_flow/2 itself happily creates a flow with no triggers (that's how a
  # seeded flow with an unresolvable stage name lands).
  defp create_new_flow(board, params) do
    case Enum.filter(@new_flow_trigger_fields, &blank_param?(params[to_string(&1)])) do
      [] ->
        attrs =
          params
          |> Map.take(["key", "isolation" | Enum.map(@new_flow_trigger_fields, &to_string/1)])
          |> Map.merge(%{"nodes" => [], "edges" => [%{"from" => "start", "to" => "done"}]})

        case Flows.create_flow(board, attrs) do
          {:ok, flow} -> {:ok, flow}
          {:error, changeset} -> {:error, changeset.errors}
        end

      missing ->
        {:error, Enum.map(missing, &{&1, {"is required", []}})}
    end
  end

  defp blank_param?(nil), do: true
  defp blank_param?(value) when is_binary(value), do: String.trim(value) == ""

  defp new_flow_form(params, errors \\ []) do
    defaults = %{
      "key" => "",
      "isolation" => "shared_clean",
      "pulls_from_stage_id" => "",
      "works_in_stage_id" => "",
      "lands_on_stage_id" => ""
    }

    # <.input> hides errors on fields LiveView still marks unused, and a stage the
    # user never touched is exactly the field we need the error on — so drop the
    # markers before building the form.
    params = Map.reject(params, fn {key, _} -> String.starts_with?(key, "_unused_") end)

    to_form(Map.merge(defaults, params), as: :flow, errors: errors)
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

  defp parse_target(""), do: nil
  defp parse_target(id), do: String.to_integer(id)

  defp lane_atom("review"), do: :review
  defp lane_atom("done"), do: :done

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
  defp apply_lane_result(socket, {:error, :not_empty}, stage_id, lane) do
    socket
    |> put_flash(:error, "That lane still has cards — move them out first.")
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
      "background:oklch(0.95 0.03 250);color:oklch(0.42 0.13 250);"
  end

  defp nav_style(false) do
    "display:block;text-align:left;border:none;border-radius:8px;padding:8px 10px;" <>
      "font-size:13.5px;text-decoration:none;font-weight:500;" <>
      "background:transparent;color:oklch(0.44 0.02 255);"
  end

  # RLY-72: horizontal tab in the mobile settings strip. Reuses nav_style/1's
  # active/inactive blue-tint values (active = oklch(0.42 0.13 250) text on
  # oklch(0.95 0.03 250)), laid out as a non-wrapping pill for a horizontal row.
  # No artboard — deliberate responsive design matching the settings chrome.
  defp tab_style(true) do
    "flex:0 0 auto;text-decoration:none;padding:10px 14px;border-radius:8px;" <>
      "font-size:13.5px;font-weight:600;white-space:nowrap;" <>
      "background:oklch(0.95 0.03 250);color:oklch(0.42 0.13 250);"
  end

  defp tab_style(false) do
    "flex:0 0 auto;text-decoration:none;padding:10px 14px;border-radius:8px;" <>
      "font-size:13.5px;font-weight:500;white-space:nowrap;" <>
      "background:transparent;color:oklch(0.44 0.02 255);"
  end

  # The mockup's limitToggleStyle (line ~1092): blue-tinted when On.
  defp wip_toggle_style(true) do
    "font-size:12px;font-weight:600;padding:5px 12px;border-radius:7px;" <>
      "border:1px solid oklch(0.75 0.10 250);background:oklch(0.96 0.03 250);color:oklch(0.45 0.13 250);"
  end

  defp wip_toggle_style(false) do
    "font-size:12px;font-weight:600;padding:5px 12px;border-radius:7px;" <>
      "border:1px solid oklch(0.90 0.006 255);background:oklch(1 0 0);color:oklch(0.52 0.02 255);"
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
      "width:9px;height:9px;border-radius:50%;border:1.5px solid oklch(0.68 0.02 255);box-sizing:border-box;display:block;flex:0 0 auto;"

  defp category_dot_style(:planning),
    do:
      "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-secondary) 0 25%, oklch(0.86 0.03 250) 25% 100%);display:block;flex:0 0 auto;"

  defp category_dot_style(:in_progress),
    do:
      "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-primary) 0 50%, oklch(0.86 0.03 250) 50% 100%);display:block;flex:0 0 auto;"

  defp category_dot_style(:complete),
    do: "width:9px;height:9px;border-radius:50%;background:var(--color-success);display:block;flex:0 0 auto;"

  defp masked(key), do: "relay_#{key.token_prefix}_…#{key.last_four}"

  defp last_used(%{last_used_at: nil}), do: "Never"
  defp last_used(%{last_used_at: at}), do: format_time(at)

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%b %d, %Y, %H:%M UTC")
end
