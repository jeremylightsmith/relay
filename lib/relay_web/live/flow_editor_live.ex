defmodule RelayWeb.FlowEditorLive do
  @moduledoc """
  Full-page flow editor. Holds an in-memory working copy (plain maps mirroring the embeds),
  validates inline against Schemas.Flow.changeset/2 after every edit (RLY-131 graph rules),
  and saves via Relay.Flows.save_definition/2 behind a Save-as-v(n+1) confirm modal. Matches
  docs/designs/Relay Flow Editor.dc.html. Read-only members (archived board) see the graph and
  inspector with every mutating control disabled.
  """
  use RelayWeb, :live_view

  alias Relay.Boards
  alias Relay.Flows
  alias RelayWeb.FlowGraphComponents
  alias RelayWeb.FlowLayout
  alias Schemas.Board

  @node_fields [:key, :type, :run, :model, :effort, :max_retries, :timeout_minutes]
  @edge_fields [:from, :to, :on, :max_loops]

  @impl true
  def mount(%{"slug" => slug, "key" => key}, _session, socket) do
    board = Boards.get_board!(socket.assigns.current_scope.user, slug)

    case Flows.get_flow(board, key) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That flow doesn't exist.")
         |> push_navigate(to: ~p"/board/#{slug}/settings?section=flows")}

      flow ->
        {:ok,
         socket
         |> assign(:page_title, "Edit flow — #{humanize(flow.key)}")
         |> assign(:board, board)
         |> assign(:stages, Boards.list_stages(board))
         |> assign(:read_only?, Board.archived?(board))
         |> assign(:selected, nil)
         |> assign(:modal, nil)
         |> load_flow(flow)}
    end
  end

  # Snapshot the persisted flow into the working copy and reset dirty/errors.
  defp load_flow(socket, flow) do
    working = %{
      nodes: Enum.map(flow.nodes, &Map.take(&1, @node_fields)),
      edges: Enum.map(flow.edges, &Map.take(&1, @edge_fields)),
      isolation: flow.isolation,
      pulls_from_stage_id: flow.pulls_from_stage_id,
      works_in_stage_id: flow.works_in_stage_id,
      lands_on_stage_id: flow.lands_on_stage_id
    }

    socket
    |> assign(:flow, flow)
    |> assign(:working, working)
    |> assign(:dirty?, false)
    |> assign(:errors, [])
    |> validate_working()
  end

  # ---- working-copy plumbing (Task 4 mutates through apply_working/2) ----

  @doc false
  def apply_working(socket, fun) when is_function(fun, 1) do
    working = fun.(socket.assigns.working)

    socket
    |> assign(:working, working)
    |> assign(:dirty?, dirty?(socket.assigns.flow, working))
    |> validate_working()
  end

  # Run the real changeset to collect graph-rule errors as plain strings (inline, blocks save).
  defp validate_working(socket) do
    working = socket.assigns.working

    changeset =
      Schemas.Flow.changeset(socket.assigns.flow, %{
        nodes: working.nodes,
        edges: working.edges,
        isolation: working.isolation
      })

    errors =
      changeset.errors
      |> Keyword.take([:nodes, :edges])
      |> Enum.map(fn {_field, {msg, _opts}} -> msg end)

    assign(socket, :errors, errors)
  end

  defp dirty?(flow, working) do
    Enum.map(flow.nodes, &Map.take(&1, @node_fields)) != working.nodes or
      Enum.map(flow.edges, &Map.take(&1, @edge_fields)) != working.edges or
      flow.isolation != working.isolation or
      flow.pulls_from_stage_id != working.pulls_from_stage_id or
      flow.works_in_stage_id != working.works_in_stage_id or
      flow.lands_on_stage_id != working.lands_on_stage_id
  end

  defp definition_dirty?(flow, working) do
    Enum.map(flow.nodes, &Map.take(&1, @node_fields)) != working.nodes or
      Enum.map(flow.edges, &Map.take(&1, @edge_fields)) != working.edges or
      flow.isolation != working.isolation
  end

  # ---- events (read-only guard first) ----

  @impl true
  def handle_event(event, _params, %{assigns: %{read_only?: true}} = socket)
      when event in ~w(validate_trigger save confirm_save discard edit_node_field select_node select_edge) do
    {:noreply, put_flash(socket, :error, "This board is archived (read-only).")}
  end

  def handle_event("select_node", %{"key" => key}, socket) do
    {:noreply, assign(socket, :selected, {:node, key})}
  end

  def handle_event("select_edge", %{"index" => i}, socket) do
    {:noreply, assign(socket, :selected, {:edge, String.to_integer(i)})}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :modal, nil)}
  end

  def handle_event("validate_trigger", %{"field" => field, "stage_id" => id}, socket) do
    key = String.to_existing_atom(field <> "_stage_id")
    id = if id == "", do: nil, else: String.to_integer(id)
    {:noreply, apply_working(socket, &Map.put(&1, key, id))}
  end

  # low-level working-copy node-field edit (the inspector calls this; Task 4 adds the form UI)
  def handle_event("edit_node_field", %{"key" => key, "field" => field, "value" => value}, socket) do
    field = String.to_existing_atom(field)
    value = cast_node_value(field, value)

    {:noreply,
     apply_working(socket, fn w ->
       nodes = Enum.map(w.nodes, fn n -> if n.key == key, do: Map.put(n, field, value), else: n end)
       %{w | nodes: nodes}
     end)}
  end

  def handle_event("save", _params, socket) do
    cond do
      socket.assigns.errors != [] ->
        {:noreply, socket}

      definition_dirty?(socket.assigns.flow, socket.assigns.working) ->
        {:noreply, assign(socket, :modal, :save)}

      true ->
        {:noreply, persist(socket)}
    end
  end

  def handle_event("confirm_save", _params, socket) do
    {:noreply, socket |> assign(:modal, nil) |> persist()}
  end

  def handle_event("discard", _params, socket) do
    {:noreply, socket |> load_flow(socket.assigns.flow) |> assign(:selected, nil)}
  end

  defp persist(socket) do
    w = socket.assigns.working

    attrs = %{
      nodes: w.nodes,
      edges: w.edges,
      isolation: w.isolation,
      pulls_from_stage_id: w.pulls_from_stage_id,
      works_in_stage_id: w.works_in_stage_id,
      lands_on_stage_id: w.lands_on_stage_id
    }

    case Flows.save_definition(socket.assigns.flow, attrs) do
      {:ok, flow} ->
        socket |> put_flash(:info, "Saved as v#{flow.version}.") |> load_flow(flow)

      {:error, changeset} ->
        errors = Enum.map(changeset.errors, fn {_f, {msg, _}} -> msg end)
        assign(socket, :errors, socket.assigns.errors ++ errors)
    end
  end

  defp cast_node_value(f, v) when f in [:max_retries, :timeout_minutes] do
    case Integer.parse(v || "") do
      {n, _} -> n
      _ -> nil
    end
  end

  defp cast_node_value(_f, ""), do: nil
  defp cast_node_value(_f, v), do: v

  defp humanize(key), do: String.replace(key, ["_", "-"], " ")

  # ---- render (chrome; inspector + canvas interactions land in Task 4) ----

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :layout, FlowLayout.layout(assigns.working.nodes, assigns.working.edges))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-col" style="height:calc(100vh - 0px);">
        <%!-- Top bar --%>
        <div style="height:52px;display:flex;align-items:center;gap:12px;padding:0 18px;border-bottom:1px solid oklch(0.92 0.006 255);background:oklch(1 0 0);">
          <nav style="font-size:13px;display:flex;align-items:center;gap:7px;">
            <.link
              navigate={~p"/board/#{@board.slug}"}
              style="color:oklch(0.52 0.02 255);font-weight:600;"
            >
              {@board.name}
            </.link>
            <span style="color:oklch(0.78 0.02 255);">/</span>
            <.link
              navigate={~p"/board/#{@board.slug}/settings?section=flows"}
              style="color:oklch(0.52 0.02 255);font-weight:600;"
            >
              Flows
            </.link>
            <span style="color:oklch(0.78 0.02 255);">/</span>
            <span style="color:oklch(0.28 0.02 255);font-weight:600;">{humanize(@flow.key)}</span>
          </nav>
          <span id="flow-editor-version-chip" style={version_chip_style(@dirty?)}>
            {if @dirty?, do: "Editing · unsaved", else: "v#{@flow.version}"}
          </span>
        </div>

        <%!-- Toolbar (palette + connect + delete land fully in Task 4; buttons present here) --%>
        <div
          id="flow-editor-toolbar"
          style="min-height:50px;display:flex;align-items:center;gap:10px;padding:7px 16px;border-bottom:1px solid oklch(0.93 0.006 255);background:oklch(0.992 0.002 255);flex-wrap:wrap;"
        >
          <span style="font-size:10.5px;font-weight:600;letter-spacing:0.06em;font-family:ui-monospace,monospace;color:oklch(0.58 0.02 255);">
            ADD NODE
          </span>
          <%!-- Task 4 fills the 5-type palette here (agent/shell/gate/parallel/human). --%>
        </div>

        <%!-- Trigger bar --%>
        <div style="display:flex;align-items:center;gap:14px;padding:11px 18px;border-bottom:1px solid oklch(0.93 0.006 255);background:oklch(1 0 0);">
          <span style="font-size:10.5px;font-weight:600;letter-spacing:0.06em;font-family:ui-monospace,monospace;color:oklch(0.58 0.02 255);">
            TRIGGER
          </span>
          <.trigger_select
            id="trigger-pulls-from"
            field="pulls_from"
            label="PULLS FROM"
            value={@working.pulls_from_stage_id}
            stages={@stages}
            disabled={@read_only?}
          />
          <span style="color:oklch(0.72 0.02 255);">→</span>
          <.trigger_select
            id="trigger-works-in"
            field="works_in"
            label="WORKS IN"
            value={@working.works_in_stage_id}
            stages={@stages}
            disabled={@read_only?}
          />
          <span style="color:oklch(0.72 0.02 255);">→</span>
          <.trigger_select
            id="trigger-lands-on"
            field="lands_on"
            label="LANDS ON SUCCESS"
            value={@working.lands_on_stage_id}
            stages={@stages}
            disabled={@read_only?}
          />
        </div>

        <%!-- Canvas + inspector --%>
        <div class="flex" style="flex:1;overflow:hidden;">
          <div style="flex:1;overflow:auto;background:oklch(0.975 0.004 250);padding:16px;">
            <FlowGraphComponents.flow_graph
              nodes={@working.nodes}
              edges={@working.edges}
              layout={@layout}
              selected={@selected}
              interactive?={!@read_only?}
              lands_on={stage_name(@stages, @working.lands_on_stage_id)}
            />
          </div>
          <%!-- Inspector panel is filled by Task 4; placeholder keeps layout stable. --%>
          <aside
            id="flow-inspector"
            style="width:328px;flex:0 0 auto;border-left:1px solid oklch(0.92 0.006 255);background:oklch(1 0 0);overflow-y:auto;"
          >
          </aside>
        </div>

        <%!-- Bottom bars --%>
        <div
          :if={@dirty?}
          id="flow-editor-unsaved-bar"
          style="padding:12px 18px;background:oklch(1 0 0);border-top:1px solid oklch(0.90 0.006 255);display:flex;align-items:center;gap:14px;"
        >
          <span style="display:flex;align-items:center;gap:7px;color:oklch(0.48 0.11 65);font-size:12.5px;font-weight:600;">
            <span style="width:8px;height:8px;border-radius:50%;background:oklch(0.70 0.13 65);">
            </span>
            Unsaved changes
          </span>
          <div
            :if={@errors != []}
            id="flow-editor-errors"
            style="background:oklch(0.98 0.02 15);border:1px solid oklch(0.89 0.06 15);border-radius:8px;padding:7px 12px;max-width:640px;color:oklch(0.48 0.12 15);font-size:12px;"
          >
            <span :for={msg <- @errors}>{msg}</span>
          </div>
          <div style="margin-left:auto;display:flex;gap:9px;">
            <button
              id="flow-editor-save"
              type="button"
              phx-click="save"
              disabled={@errors != [] or @read_only?}
              style={save_button_style(@errors == [] and !@read_only?)}
            >
              Save as v{@flow.version + 1}
            </button>
            <button
              id="flow-editor-discard"
              type="button"
              phx-click="discard"
              style="background:transparent;border:1px solid oklch(0.90 0.006 255);color:oklch(0.48 0.02 255);border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;"
            >
              Discard
            </button>
          </div>
        </div>

        <div
          :if={!@dirty?}
          id="flow-editor-saved-bar"
          style="padding:11px 18px;border-top:1px solid oklch(0.93 0.006 255);display:flex;align-items:center;gap:12px;"
        >
          <span style="width:8px;height:8px;border-radius:50%;background:oklch(0.60 0.13 155);">
          </span>
          <span style="font-size:12.5px;color:oklch(0.55 0.02 255);">
            All changes saved ·
            <span style="font-family:ui-monospace,monospace;">v{@flow.version}</span>
          </span>
          <span style="margin-left:auto;font-family:ui-monospace,monospace;font-size:11.5px;color:oklch(0.60 0.02 255);">
            {stats(@working)}
          </span>
          <%!-- Task 4 appends the diff-vs-default affordance here. --%>
        </div>
      </div>

      <%!-- Save confirm modal --%>
      <div
        :if={@modal == :save}
        id="flow-save-modal"
        phx-window-keydown="close_modal"
        phx-key="escape"
      >
        <div
          phx-click="close_modal"
          style="position:fixed;inset:0;background:oklch(0.30 0.02 255/0.28);z-index:50;"
        >
        </div>
        <div style="position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);z-index:51;width:min(480px,92vw);background:oklch(1 0 0);border:1px solid oklch(0.90 0.006 255);border-radius:16px;">
          <div style="padding:22px 24px;display:flex;flex-direction:column;gap:12px;">
            <div style="display:flex;align-items:center;gap:11px;">
              <span style="width:32px;height:32px;border-radius:9px;background:oklch(0.56 0.16 292);color:white;display:flex;align-items:center;justify-content:center;font-weight:700;">
                ↑
              </span>
              <span style="font-size:17px;font-weight:600;color:oklch(0.24 0.02 255);">
                Save as v{@flow.version + 1}?
              </span>
            </div>
            <p style="font-size:13.5px;line-height:1.6;color:oklch(0.46 0.02 255);">
              Saving bumps this flow from <span style="font-family:ui-monospace,monospace;">v{@flow.version} → v{@flow.version + 1}</span>. Every new run started from now on uses v{@flow.version +
                1}.
            </p>
            <div
              :if={Flows.mid_run_count(@flow) > 0}
              id="flow-save-modal-midrun"
              style="background:oklch(0.98 0.02 292);border:1px solid oklch(0.91 0.04 292);border-radius:10px;padding:12px 14px;color:oklch(0.44 0.14 292);font-size:12.5px;"
            >
              {Flows.mid_run_count(@flow)} cards are mid-run on v{@flow.version}. They finish on v{@flow.version} — this edit won't touch them.
            </div>
          </div>
          <div style="background:oklch(0.985 0.004 250);border-top:1px solid oklch(0.94 0.005 255);padding:14px 24px;display:flex;justify-content:flex-end;gap:9px;">
            <button
              type="button"
              phx-click="close_modal"
              style="background:oklch(1 0 0);border:1px solid oklch(0.88 0.01 255);color:oklch(0.42 0.02 255);border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;"
            >
              Cancel
            </button>
            <button
              id="flow-save-confirm"
              type="button"
              phx-click="confirm_save"
              style="background:oklch(0.56 0.16 292);color:white;border:none;border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;"
            >
              Save as v{@flow.version + 1}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---- render helpers ----

  attr :id, :string, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :stages, :list, required: true
  attr :disabled, :boolean, default: false

  defp trigger_select(assigns) do
    ~H"""
    <form id={@id} phx-change="validate_trigger" style="display:flex;flex-direction:column;gap:3px;">
      <input type="hidden" name="field" value={@field} />
      <label style="font-size:9.5px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
        {@label}
      </label>
      <select
        name="stage_id"
        disabled={@disabled}
        style="border:1px solid oklch(0.90 0.006 255);background:oklch(0.99 0.002 255);border-radius:8px;padding:6px 10px;font-size:12.5px;font-family:ui-monospace,monospace;color:oklch(0.40 0.02 255);"
      >
        <option value="">—</option>
        <option :for={s <- @stages} value={s.id} selected={s.id == @value}>{s.name}</option>
      </select>
    </form>
    """
  end

  defp version_chip_style(true),
    do:
      "font-size:11px;font-weight:600;font-family:ui-monospace,monospace;padding:4px 10px;border-radius:6px;background:oklch(0.97 0.04 75);color:oklch(0.48 0.11 65);"

  defp version_chip_style(false),
    do:
      "font-size:11px;font-weight:600;font-family:ui-monospace,monospace;padding:4px 10px;border-radius:6px;background:oklch(0.96 0.004 255);color:oklch(0.46 0.02 255);"

  defp save_button_style(true),
    do:
      "background:oklch(0.56 0.16 292);color:white;border:none;border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;cursor:pointer;"

  defp save_button_style(false),
    do:
      "background:oklch(0.82 0.05 250);color:white;border:none;border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;cursor:not-allowed;opacity:0.7;"

  defp stage_name(stages, id), do: Enum.find_value(stages, &(&1.id == id && &1.name))

  defp stats(working) do
    nodes = length(working.nodes)
    edges = length(working.edges)
    loops = Enum.count(working.edges, &(&1[:max_loops] not in [nil, 0]))
    "#{nodes} nodes · #{edges} edges · #{loops} loops"
  end
end
