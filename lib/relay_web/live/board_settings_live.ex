defmodule RelayWeb.BoardSettingsLive do
  @moduledoc """
  Board settings (`/board/settings`) — the mockup's two-pane Board Settings
  (MMF 12): a 210px `BOARD` rail navigating between the **Stages** pane
  (rename / describe / reorder / add / delete stages, the meant-for owner
  segmented control, and the MMF 10b Review/Done sub-lane toggles) and the
  **API keys** pane (MMF 08, markup unchanged — restyling it is out of
  scope; General and Members arrive with MMFs 19/17).

  All stage mutations go through `Relay.Boards`, which broadcasts
  `{:stages_changed, board_id}` (MMF 18) so every open board re-renders
  live. `Stage.owner` is the *meant-for* designation only — changing it
  never touches any card's owner rows.
  """

  use RelayWeb, :live_view

  alias Relay.ApiKeys
  alias Relay.Boards

  @categories [:unstarted, :planning, :in_progress, :complete]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div id="board-settings" style="display:flex;align-items:stretch;min-height:calc(100vh - 74px);">
        <%!-- Left rail — mockup "Relay Board.dc.html" lines ~176-183 --%>
        <nav
          id="settings-rail"
          style="width:210px;flex:0 0 auto;border-right:1px solid oklch(0.93 0.006 255);background:oklch(0.992 0.002 255);padding:22px 14px;display:flex;flex-direction:column;gap:3px;"
        >
          <div
            class="font-mono"
            style="font-size:10px;font-weight:600;letter-spacing:0.08em;color:oklch(0.60 0.02 255);padding:4px 10px 8px 10px;"
          >
            BOARD
          </div>
          <.link
            patch={~p"/board/settings"}
            id="settings-nav-stages"
            style={nav_style(@section == :stages)}
          >
            Stages
          </.link>
          <.link
            patch={~p"/board/settings?section=keys"}
            id="settings-nav-keys"
            style={nav_style(@section == :keys)}
          >
            API keys
          </.link>
          <.link
            navigate={~p"/board"}
            id="back-to-board"
            class="font-mono"
            style="margin-top:auto;font-size:11px;color:oklch(0.55 0.02 255);padding:8px 10px;text-decoration:none;"
          >
            ← Back to board
          </.link>
        </nav>

        <%!-- Content pane — mockup lines ~186-187 --%>
        <div style="flex:1;overflow-y:auto;background:oklch(0.985 0.004 250);">
          <div style="max-width:760px;margin:0 auto;padding:34px 40px 84px 40px;">
            <section :if={@section == :stages} id="stages-pane">
              <h1 style="font-size:22px;font-weight:600;letter-spacing:-0.02em;margin:0 0 6px 0;color:oklch(0.26 0.02 255);">
                Stages
              </h1>
              <%!-- Mockup line ~217; the WIP-limit mention is deferred to MMF 11. --%>
              <p style="font-size:14px;line-height:1.55;color:oklch(0.50 0.02 255);margin:0 0 12px 0;max-width:560px;">
                Stages live inside four categories — <b style="color:oklch(0.34 0.02 255);">Unstarted</b>, <b style="color:oklch(0.34 0.02 255);">Planning</b>, <b style="color:oklch(0.34 0.02 255);">In progress</b>, and
                <b style="color:oklch(0.34 0.02 255);">Complete</b>
                — so everyone knows what a stage <i>means</i>. Use the arrows to move a stage
                up or down — cross into another category and it takes on that meaning. Set
                each stage's owner and whether finished work waits in a Done sub-column.
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
                    <form
                      id={"stage-#{stage.id}-form"}
                      phx-change="update_stage"
                      style="display:flex;flex-direction:column;gap:14px;"
                    >
                      <input type="hidden" name="stage_id" value={stage.id} />
                      <div style="display:flex;align-items:center;gap:10px;">
                        <span
                          class="stage-owner-swatch"
                          data-owner={stage.owner}
                          style={"width:9px;height:9px;border-radius:3px;flex:0 0 auto;background:#{owner_color(stage.owner)};"}
                        >
                        </span>
                        <input
                          id={"stage-#{stage.id}-name"}
                          type="text"
                          name="stage[name]"
                          value={stage.name}
                          phx-debounce="300"
                          style="flex:1;border:none;outline:none;font-size:15px;font-weight:600;letter-spacing:-0.01em;color:oklch(0.26 0.02 255);background:transparent;"
                        />
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
                      <input
                        id={"stage-#{stage.id}-description"}
                        type="text"
                        name="stage[description]"
                        value={stage.description}
                        placeholder="Describe what happens in this stage…"
                        phx-debounce="300"
                        style="border:1px solid oklch(0.92 0.006 255);border-radius:8px;padding:8px 11px;font-size:13px;color:oklch(0.42 0.02 255);background:oklch(0.99 0.002 255);outline:none;"
                      />
                    </form>
                    <%!-- Controls row — MMF 11's WIP control slots in between
                         OWNER and DONE COLUMN (mockup lines ~241-262). --%>
                    <div style="display:flex;align-items:center;gap:20px;flex-wrap:wrap;">
                      <div style="display:flex;align-items:center;gap:9px;">
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
                          OWNER
                        </span>
                        <div style="display:inline-flex;background:oklch(0.96 0.004 255);border:1px solid oklch(0.91 0.006 255);border-radius:8px;padding:3px;gap:2px;">
                          <button
                            type="button"
                            id={"stage-#{stage.id}-owner-human"}
                            phx-click="set_owner"
                            phx-value-stage-id={stage.id}
                            phx-value-owner="human"
                            style={segment_style(stage.owner == :human)}
                          >
                            Human
                          </button>
                          <button
                            type="button"
                            id={"stage-#{stage.id}-owner-ai"}
                            phx-click="set_owner"
                            phx-value-stage-id={stage.id}
                            phx-value-owner="ai"
                            style={segment_style(stage.owner == :ai)}
                          >
                            AI
                          </button>
                        </div>
                      </div>
                      <div style="display:flex;align-items:center;gap:10px;">
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
                          DONE COLUMN
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
                    </div>
                    <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;border-top:1px dashed oklch(0.94 0.006 255);padding-top:12px;">
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
                      <span
                        :if={lane_on?(@lane_map, stage.id, :review)}
                        style="font-size:11px;line-height:1.4;color:oklch(0.55 0.02 255);"
                      >
                        Finished work waits in <b style="color:oklch(0.40 0.02 255);">Review</b>
                        for a human to approve. Rejected work returns to this stage's
                        In progress lane.
                      </span>
                    </div>
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

            <section
              :if={@section == :keys}
              id="api-key-pane"
              class="card border border-base-300 bg-base-100"
            >
              <div class="card-body space-y-4">
                <div>
                  <h2 class="card-title text-base">API key</h2>
                  <p class="text-sm text-base-content/60">
                    Lets external tools (like Claude Code) act on this board. One key per board.
                  </p>
                </div>

                <div :if={@revealed_token} id="api-key-reveal" class="space-y-2">
                  <div id="api-key-reveal-note" class="alert alert-warning text-sm">
                    <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
                    <span>Copy this key now — you won't be able to see it again.</span>
                  </div>
                  <div class="join w-full">
                    <code
                      id="api-key-secret"
                      class="join-item flex flex-1 items-center overflow-x-auto border border-base-300 bg-base-200 px-3 py-2 font-mono text-sm"
                    >
                      {@revealed_token}
                    </code>
                    <button
                      id="copy-key"
                      type="button"
                      class="join-item btn btn-primary"
                      phx-hook=".CopyKey"
                      data-target="api-key-secret"
                    >
                      <.icon name="hero-clipboard" class="size-4" /> Copy
                    </button>
                  </div>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyKey">
                    export default {
                      mounted() {
                        this.el.addEventListener("click", () => {
                          const target = document.getElementById(this.el.dataset.target)
                          if (target) navigator.clipboard.writeText(target.textContent.trim())
                        })
                      }
                    }
                  </script>
                </div>

                <%= if @api_key do %>
                  <dl id="api-key-details" class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1 text-sm">
                    <dt class="text-base-content/60">Name</dt>
                    <dd id="api-key-name">{@api_key.name}</dd>
                    <dt class="text-base-content/60">Key</dt>
                    <dd id="api-key-masked" class="font-mono">{masked(@api_key)}</dd>
                    <dt class="text-base-content/60">Created</dt>
                    <dd id="api-key-created">{format_time(@api_key.inserted_at)}</dd>
                    <dt class="text-base-content/60">Last used</dt>
                    <dd id="api-key-last-used">{last_used(@api_key)}</dd>
                  </dl>
                  <div class="card-actions">
                    <button
                      id="regenerate-key"
                      class="btn btn-outline btn-sm"
                      phx-click="regenerate_key"
                      data-confirm="Regenerate the key? The current key stops working immediately."
                    >
                      <.icon name="hero-arrow-path" class="size-4" /> Regenerate
                    </button>
                    <button
                      id="revoke-key"
                      class="btn btn-outline btn-error btn-sm"
                      phx-click="revoke_key"
                      data-confirm="Revoke the key? Tools using it will lose access."
                    >
                      <.icon name="hero-trash" class="size-4" /> Revoke
                    </button>
                  </div>
                <% else %>
                  <div class="card-actions">
                    <button id="generate-key" class="btn btn-primary btn-sm" phx-click="generate_key">
                      <.icon name="hero-key" class="size-4" /> Generate key
                    </button>
                  </div>
                <% end %>
              </div>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(:page_title, "Board settings")
     |> assign(:board, board)
     |> assign(:api_key, ApiKeys.get_key(board))
     |> assign(:revealed_token, nil)
     |> assign(:lane_nonce, %{})
     |> refresh_stages()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :section, section(params))}
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

  def handle_event("update_stage", %{"stage_id" => stage_id, "stage" => stage_params}, socket) do
    stage = find_stage(socket, stage_id)
    attrs = Map.take(stage_params, ["name", "description"])

    case Boards.update_stage(stage, attrs) do
      {:ok, _stage} ->
        {:noreply, refresh_stages(socket)}

      {:error, _changeset} ->
        {:noreply, socket |> put_flash(:error, "Stage name cannot be blank.") |> refresh_stages()}
    end
  end

  def handle_event("set_owner", %{"stage-id" => stage_id, "owner" => owner}, socket) when owner in ["human", "ai"] do
    {:ok, _stage} = Boards.update_stage(find_stage(socket, stage_id), %{owner: owner_atom(owner)})
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

  defp section(%{"section" => "keys"}), do: :keys
  defp section(_params), do: :stages

  # Reloads the main stages and lane map from the DB after any mutation, and
  # groups them for the pane. All four categories always render so an
  # emptied category keeps its "+ Add stage" button.
  defp refresh_stages(socket) do
    board = socket.assigns.board
    mains = board |> Boards.list_stages() |> Enum.filter(&(&1.lane == :main))

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

  defp lane_atom("review"), do: :review
  defp lane_atom("done"), do: :done

  defp owner_atom("human"), do: :human
  defp owner_atom("ai"), do: :ai

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
    |> Enum.filter(&(&1.lane != :main))
    |> Enum.group_by(& &1.parent_id, & &1.lane)
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

  # The mockup's segActive / segIdle (lines ~1084-1085).
  defp segment_style(true) do
    "font-size:12px;font-weight:600;padding:6px 13px;border-radius:6px;" <>
      "background:oklch(1 0 0);color:oklch(0.30 0.02 255);border:none;" <>
      "box-shadow:0 1px 2px oklch(0.5 0.03 255 / 0.12);white-space:nowrap;"
  end

  defp segment_style(false) do
    "font-size:12px;font-weight:600;padding:6px 13px;border-radius:6px;" <>
      "background:transparent;color:oklch(0.52 0.02 255);border:none;white-space:nowrap;"
  end

  # Human = blue, AI = violet (theme tokens in app.css).
  defp owner_color(:human), do: "var(--color-primary)"
  defp owner_color(:ai), do: "var(--color-secondary)"

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
