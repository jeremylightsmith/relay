defmodule RelayWeb.FlowEditorComponents do
  @moduledoc """
  Function components for `RelayWeb.FlowEditorLive`: the node/edge inspector panel, the
  ADD NODE palette, and the Connect edge / Delete toolbar buttons. Kept separate from the
  LiveView to keep it lean. Concrete visual values follow
  docs/designs/Relay Flow Editor.dc.html (§inspector lines ~127-202, palette ~466-476).
  """
  use Phoenix.Component

  @type_tag %{
    agent: {"AGENT", "oklch(0.46 0.14 292)", "oklch(0.95 0.04 292)"},
    shell: {"SHELL", "oklch(0.48 0.02 255)", "oklch(0.95 0.004 255)"},
    gate: {"GATE", "oklch(0.48 0.11 65)", "oklch(0.96 0.02 75)"},
    parallel: {"PARALLEL", "oklch(0.42 0.10 195)", "oklch(0.95 0.03 195)"},
    human: {"HUMAN", "oklch(0.44 0.13 250)", "oklch(0.95 0.03 250)"}
  }

  @palette_types [
    {:agent, "Agent", "oklch(0.56 0.16 292)"},
    {:shell, "Shell", "oklch(0.55 0.02 255)"},
    {:gate, "Gate", "oklch(0.70 0.13 65)"},
    {:parallel, "Parallel", "oklch(0.62 0.13 195)"},
    {:human, "Human", "oklch(0.60 0.14 250)"}
  ]

  @models ["inherit", "haiku", "sonnet", "opus"]
  @efforts ["low", "medium", "high"]
  @outcomes ["succeeded", "failed", "partial", "needs_input"]

  # ---- ADD NODE palette ----

  attr :read_only?, :boolean, default: false

  def palette(assigns) do
    assigns = assign(assigns, :types, @palette_types)

    ~H"""
    <div style="display:flex;gap:5px;">
      <button
        :for={{type, label, accent} <- @types}
        id={"palette-#{type}"}
        type="button"
        phx-click="add_node"
        phx-value-type={type}
        disabled={@read_only?}
        style="display:flex;align-items:center;gap:6px;background:oklch(1 0 0);border:1px solid oklch(0.90 0.006 255);color:oklch(0.38 0.02 255);border-radius:8px;padding:6px 10px;font-size:12px;font-weight:600;"
      >
        <span style={"width:9px;height:9px;border-radius:#{if type == :gate, do: "0;transform:rotate(45deg)", else: "3px"};background:#{accent};display:inline-block;"}>
        </span>
        {label}
      </button>
    </div>
    """
  end

  # ---- Connect edge / Delete toolbar buttons ----

  attr :connecting?, :boolean, default: false
  attr :has_selection?, :boolean, default: false
  attr :read_only?, :boolean, default: false

  def toolbar_actions(assigns) do
    ~H"""
    <button
      id="toolbar-connect-edge"
      type="button"
      phx-click="connect_edge"
      disabled={@read_only?}
      style={connect_button_style(@connecting?)}
    >
      <span style="width:14px;height:8px;border:1.5px solid currentColor;border-radius:5px;display:inline-block;">
      </span>
      {if @connecting?, do: "Cancel connect", else: "Connect edge"}
    </button>
    <button
      id="toolbar-delete"
      type="button"
      phx-click="delete_selected"
      disabled={@read_only? or !@has_selection?}
      style="display:flex;align-items:center;gap:7px;background:oklch(0.98 0.015 15);border:1px solid oklch(0.88 0.05 15);color:oklch(0.52 0.16 15);border-radius:8px;padding:7px 12px;font-size:12.5px;font-weight:600;"
    >
      Delete
    </button>
    """
  end

  defp connect_button_style(true),
    do:
      "display:flex;align-items:center;gap:7px;background:oklch(0.97 0.04 292);border:1px solid oklch(0.80 0.10 292);color:oklch(0.46 0.14 292);border-radius:8px;padding:7px 12px;font-size:12.5px;font-weight:600;"

  defp connect_button_style(false),
    do:
      "display:flex;align-items:center;gap:7px;background:oklch(1 0 0);border:1px solid oklch(0.90 0.006 255);color:oklch(0.42 0.02 255);border-radius:8px;padding:7px 12px;font-size:12.5px;font-weight:600;"

  # ---- Node inspector ----

  attr :node, :map, required: true
  attr :edges, :list, required: true, doc: "the node's outgoing working-copy edges"
  attr :referenced_count, :integer, required: true
  attr :read_only?, :boolean, default: false

  def node_inspector(assigns) do
    assigns = assign(assigns, models: @models, efforts: @efforts)

    ~H"""
    <div>
      <div style="padding:16px 18px;border-bottom:1px solid oklch(0.94 0.005 255);display:flex;flex-direction:column;gap:10px;">
        <div style="display:flex;align-items:center;gap:8px;">
          <span style={type_badge_style(@node.type)}>{type_tag(@node.type)}</span>
          <span style="flex:1;"></span>
          <button
            id="inspector-delete-node"
            type="button"
            phx-click="delete_selected"
            disabled={@read_only? or @referenced_count > 0}
            style={delete_button_style(@referenced_count > 0)}
          >
            Delete node
          </button>
        </div>
        <div style="display:flex;flex-direction:column;gap:3px;">
          <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
            NODE NAME
          </span>
          <form id="inspector-node-rename-form" phx-change="rename_node">
            <input type="hidden" name="key" value={@node.key} />
            <input
              id="inspector-node-name"
              name="value"
              type="text"
              value={@node.key}
              disabled={@read_only?}
              phx-debounce="blur"
              style="width:100%;padding:7px 9px;border:1px solid oklch(0.90 0.006 255);border-radius:7px;font-size:15px;font-weight:600;color:oklch(0.26 0.02 255);background:oklch(0.99 0.002 255);"
            />
          </form>
        </div>
        <div
          :if={@referenced_count > 0}
          id="inspector-delete-guard"
          style="display:flex;align-items:center;gap:7px;background:oklch(0.98 0.015 15);border:1px solid oklch(0.90 0.04 15);border-radius:7px;padding:7px 9px;font-size:11px;color:oklch(0.50 0.10 15);"
        >
          <span style="font-weight:700;">⚠</span>
          Referenced by {@referenced_count} edge{if @referenced_count != 1, do: "s"} — clear them before deleting
        </div>
      </div>

      <div style="padding:16px 18px;display:flex;flex-direction:column;gap:18px;">
        <div style="display:flex;flex-direction:column;gap:7px;">
          <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
            {main_label(@node.type)}
          </span>
          <form id="inspector-node-form" phx-change="edit_node_field">
            <input type="hidden" name="key" value={@node.key} />
            <input type="hidden" name="field" value="run" />
            <textarea
              name="value"
              disabled={@read_only?}
              style="width:100%;border:1px solid oklch(0.90 0.006 255);background:oklch(1 0 0);border-radius:8px;padding:10px 11px;font-size:12px;line-height:1.55;color:oklch(0.36 0.02 255);font-family:ui-monospace,monospace;white-space:pre-wrap;min-height:96px;"
            >{@node.run}</textarea>
          </form>
        </div>

        <div :if={@node.type == :agent} style="display:flex;flex-direction:column;gap:8px;">
          <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
            MODEL
          </span>
          <div style="display:flex;gap:6px;flex-wrap:wrap;">
            <button
              :for={model <- @models}
              id={"inspector-model-#{model}"}
              type="button"
              phx-click="edit_node_field"
              phx-value-key={@node.key}
              phx-value-field="model"
              phx-value-value={if model == "inherit", do: "", else: model}
              disabled={@read_only?}
              style={chip_style(model_selected?(@node, model))}
            >
              {model}
            </button>
          </div>
        </div>

        <div :if={@node.type == :agent} style="display:flex;flex-direction:column;gap:8px;">
          <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
            EFFORT
          </span>
          <div style="display:inline-flex;background:oklch(0.96 0.004 255);border:1px solid oklch(0.90 0.006 255);border-radius:9px;padding:3px;gap:2px;align-self:flex-start;">
            <button
              :for={effort <- @efforts}
              id={"inspector-effort-#{effort}"}
              type="button"
              phx-click="edit_node_field"
              phx-value-key={@node.key}
              phx-value-field="effort"
              phx-value-value={effort}
              disabled={@read_only?}
              style={segment_style(@node.effort == effort)}
            >
              {effort}
            </button>
          </div>
        </div>

        <div style="display:flex;gap:16px;">
          <div style="display:flex;flex-direction:column;gap:8px;">
            <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
              MAX RETRIES
            </span>
            <div style="display:inline-flex;align-items:center;border:1px solid oklch(0.90 0.006 255);border-radius:8px;overflow:hidden;align-self:flex-start;">
              <button
                id="inspector-max-retries-dec"
                type="button"
                phx-click="edit_node_field"
                phx-value-key={@node.key}
                phx-value-field="max_retries"
                phx-value-value={stepper_value(@node.max_retries, -1)}
                disabled={@read_only?}
                style="width:28px;height:34px;display:flex;align-items:center;justify-content:center;color:oklch(0.55 0.02 255);font-size:16px;border:0;background:oklch(1 0 0);"
              >
                −
              </button>
              <span style="width:34px;text-align:center;font-size:13px;font-family:ui-monospace,monospace;">
                {@node.max_retries || 0}
              </span>
              <button
                id="inspector-max-retries-inc"
                type="button"
                phx-click="edit_node_field"
                phx-value-key={@node.key}
                phx-value-field="max_retries"
                phx-value-value={stepper_value(@node.max_retries, 1)}
                disabled={@read_only?}
                style="width:28px;height:34px;display:flex;align-items:center;justify-content:center;color:oklch(0.55 0.02 255);font-size:16px;border:0;background:oklch(1 0 0);"
              >
                +
              </button>
            </div>
          </div>
          <div style="display:flex;flex-direction:column;gap:8px;flex:1;">
            <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
              TIMEOUT (MIN)
            </span>
            <form id="inspector-node-timeout-form" phx-change="edit_node_field">
              <input type="hidden" name="key" value={@node.key} />
              <input type="hidden" name="field" value="timeout_minutes" />
              <input
                name="value"
                type="text"
                value={@node.timeout_minutes}
                disabled={@read_only?}
                style="width:100%;border:1px solid oklch(0.90 0.006 255);border-radius:8px;padding:8px 11px;font-size:13px;font-family:ui-monospace,monospace;color:oklch(0.32 0.02 255);background:oklch(0.99 0.002 255);"
              />
            </form>
          </div>
        </div>

        <div style="display:flex;flex-direction:column;gap:9px;">
          <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
            OUTGOING EDGES · routed on outcome
          </span>
          <div
            :for={edge <- @edges}
            style="display:flex;align-items:center;gap:8px;border:1px solid oklch(0.93 0.006 255);border-radius:8px;padding:8px 10px;background:oklch(0.994 0.002 255);"
          >
            <span style="font-size:10px;font-weight:600;font-family:ui-monospace,monospace;padding:2px 7px;border-radius:5px;background:oklch(0.96 0.004 255);color:oklch(0.48 0.02 255);">
              {edge.on}
            </span>
            <span style="color:oklch(0.70 0.02 255);font-size:11px;">→</span>
            <span style="font-size:12px;font-weight:500;color:oklch(0.34 0.02 255);flex:1;">
              {edge.to}
            </span>
            <span
              :if={edge.max_loops}
              style="font-size:9.5px;font-weight:600;font-family:ui-monospace,monospace;color:oklch(0.52 0.11 65);background:oklch(0.98 0.04 75);border-radius:4px;padding:2px 5px;"
            >
              max {edge.max_loops}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---- Edge inspector ----

  attr :edge, :map, required: true
  attr :index, :integer, required: true
  attr :read_only?, :boolean, default: false

  def edge_inspector(assigns) do
    assigns = assign(assigns, :outcomes, @outcomes)

    ~H"""
    <div style="padding:16px 18px;display:flex;flex-direction:column;gap:16px;">
      <div style="display:flex;align-items:center;gap:8px;">
        <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
          EDGE
        </span>
        <span style="flex:1;"></span>
        <button
          id="inspector-delete-edge"
          type="button"
          phx-click="delete_selected"
          disabled={@read_only?}
          style="background:oklch(0.98 0.015 15);border:1px solid oklch(0.90 0.05 15);color:oklch(0.54 0.14 15);border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;"
        >
          Delete edge
        </button>
      </div>

      <div style="display:flex;align-items:center;gap:8px;font-size:13px;font-weight:600;">
        <span
          id="inspector-edge-from"
          style="font-family:ui-monospace,monospace;color:oklch(0.34 0.02 255);"
        >
          {@edge.from}
        </span>
        <span style="color:oklch(0.70 0.02 255);">→</span>
        <span
          id="inspector-edge-to"
          style="font-family:ui-monospace,monospace;color:oklch(0.34 0.02 255);"
        >
          {@edge.to}
        </span>
      </div>

      <div style="display:flex;flex-direction:column;gap:7px;">
        <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
          OUTCOME
        </span>
        <form id="inspector-edge-outcome-form" phx-change="edit_edge">
          <input type="hidden" name="index" value={@index} />
          <input type="hidden" name="field" value="on" />
          <select
            name="value"
            disabled={@read_only?}
            style="border:1px solid oklch(0.90 0.006 255);background:oklch(0.99 0.002 255);border-radius:8px;padding:6px 10px;font-size:12.5px;font-family:ui-monospace,monospace;color:oklch(0.40 0.02 255);"
          >
            <option
              :for={outcome <- @outcomes}
              value={outcome}
              selected={to_string(@edge.on) == outcome}
            >
              {outcome}
            </option>
          </select>
        </form>
      </div>

      <div style="display:flex;flex-direction:column;gap:8px;">
        <span style="font-size:10px;font-family:ui-monospace,monospace;color:oklch(0.62 0.02 255);">
          MAX LOOPS
        </span>
        <div style="display:inline-flex;align-items:center;border:1px solid oklch(0.90 0.006 255);border-radius:8px;overflow:hidden;align-self:flex-start;">
          <button
            id="inspector-max-loops-dec"
            type="button"
            phx-click="edit_edge"
            phx-value-index={@index}
            phx-value-field="max_loops"
            phx-value-value={stepper_value(@edge.max_loops, -1)}
            disabled={@read_only?}
            style="width:28px;height:34px;display:flex;align-items:center;justify-content:center;color:oklch(0.55 0.02 255);font-size:16px;border:0;background:oklch(1 0 0);"
          >
            −
          </button>
          <span style="width:34px;text-align:center;font-size:13px;font-family:ui-monospace,monospace;">
            {@edge.max_loops || 0}
          </span>
          <button
            id="inspector-max-loops-inc"
            type="button"
            phx-click="edit_edge"
            phx-value-index={@index}
            phx-value-field="max_loops"
            phx-value-value={stepper_value(@edge.max_loops, 1)}
            disabled={@read_only?}
            style="width:28px;height:34px;display:flex;align-items:center;justify-content:center;color:oklch(0.55 0.02 255);font-size:16px;border:0;background:oklch(1 0 0);"
          >
            +
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ---- Diff modal ----

  attr :diff, :map, required: true

  def diff_modal(assigns) do
    ~H"""
    <div
      id="flow-diff-modal"
      phx-window-keydown="close_modal"
      phx-key="escape"
    >
      <div
        phx-click="close_modal"
        style="position:fixed;inset:0;background:oklch(0.30 0.02 255/0.28);z-index:50;"
      >
      </div>
      <div style="position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);z-index:51;width:min(560px,92vw);max-height:80vh;overflow-y:auto;background:oklch(1 0 0);border:1px solid oklch(0.90 0.006 255);border-radius:16px;">
        <div style="padding:20px 22px;display:flex;flex-direction:column;gap:14px;">
          <span style="font-size:16px;font-weight:600;color:oklch(0.24 0.02 255);">
            Diff vs shipped default
          </span>

          <div style="display:flex;flex-direction:column;gap:8px;font-family:ui-monospace,monospace;font-size:12px;">
            <div :if={@diff.nodes.added != []}>
              <div style="font-weight:600;color:oklch(0.48 0.02 255);">Nodes added</div>
              <div :for={key <- @diff.nodes.added} style="color:oklch(0.44 0.13 155);">+ {key}</div>
            </div>
            <div :if={@diff.nodes.removed != []}>
              <div style="font-weight:600;color:oklch(0.48 0.02 255);">Nodes removed</div>
              <div :for={key <- @diff.nodes.removed} style="color:oklch(0.52 0.15 22);">- {key}</div>
            </div>
            <div :if={@diff.nodes.changed != []}>
              <div style="font-weight:600;color:oklch(0.48 0.02 255);">Nodes changed</div>
              <div :for={c <- @diff.nodes.changed} style="color:oklch(0.46 0.14 292);">
                ~ {c.key} ({Enum.join(c.fields, ", ")})
              </div>
            </div>
            <div :if={@diff.edges.added != []}>
              <div style="font-weight:600;color:oklch(0.48 0.02 255);">Edges added</div>
              <div :for={{from, to, on} <- @diff.edges.added} style="color:oklch(0.44 0.13 155);">
                + {from} → {to} on {on}
              </div>
            </div>
            <div :if={@diff.edges.removed != []}>
              <div style="font-weight:600;color:oklch(0.48 0.02 255);">Edges removed</div>
              <div :for={{from, to, on} <- @diff.edges.removed} style="color:oklch(0.52 0.15 22);">
                - {from} → {to} on {on}
              </div>
            </div>
          </div>
        </div>
        <div style="background:oklch(0.985 0.004 250);border-top:1px solid oklch(0.94 0.005 255);padding:14px 22px;display:flex;justify-content:flex-end;">
          <button
            type="button"
            phx-click="close_modal"
            style="background:oklch(1 0 0);border:1px solid oklch(0.88 0.01 255);color:oklch(0.42 0.02 255);border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;"
          >
            Close
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ---- Reset confirm modal ----

  attr :flow_name, :string, required: true

  def reset_confirm_modal(assigns) do
    ~H"""
    <div
      id="flow-reset-modal"
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
          <span style="font-size:17px;font-weight:600;color:oklch(0.24 0.02 255);">
            Reset the {@flow_name} flow to the shipped default?
          </span>
          <p style="font-size:13.5px;line-height:1.6;color:oklch(0.46 0.02 255);">
            Replace this flow's definition with the shipped default? Your customizations are
            overwritten. The flow's triggers and on/off state are untouched.
          </p>
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
            id="flow-reset-confirm"
            type="button"
            phx-click="confirm_reset"
            style="background:oklch(0.62 0.14 65);color:oklch(1 0 0);border:none;border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;"
          >
            Reset to default
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ---- private helpers ----

  defp type_tag(type), do: elem(Map.fetch!(@type_tag, type), 0)

  defp type_badge_style(type) do
    {_tag, color, bg} = Map.fetch!(@type_tag, type)

    "font-size:9px;font-weight:700;letter-spacing:0.06em;font-family:ui-monospace,monospace;color:#{color};background:#{bg};padding:3px 8px;border-radius:5px;"
  end

  defp delete_button_style(true),
    do:
      "background:oklch(0.98 0.015 15);border:1px solid oklch(0.90 0.05 15);color:oklch(0.54 0.14 15);border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;opacity:0.55;cursor:not-allowed;"

  defp delete_button_style(false),
    do:
      "background:oklch(0.98 0.015 15);border:1px solid oklch(0.90 0.05 15);color:oklch(0.54 0.14 15);border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;"

  defp main_label(:shell), do: "COMMAND"
  defp main_label(:gate), do: "CONDITION"
  defp main_label(_), do: "RUN PROMPT"

  defp model_selected?(%{model: nil}, "inherit"), do: true
  defp model_selected?(%{model: model}, model), do: true
  defp model_selected?(_, _), do: false

  defp chip_style(true),
    do:
      "font-size:12px;font-weight:600;padding:6px 12px;border-radius:7px;border:1px solid oklch(0.56 0.16 292);background:oklch(0.97 0.04 292);color:oklch(0.44 0.14 292);font-family:ui-monospace,monospace;"

  defp chip_style(false),
    do:
      "font-size:12px;font-weight:600;padding:6px 12px;border-radius:7px;border:1px solid oklch(0.90 0.006 255);background:oklch(1 0 0);color:oklch(0.46 0.02 255);font-family:ui-monospace,monospace;"

  defp segment_style(true),
    do:
      "font-size:12px;font-weight:600;padding:6px 14px;border-radius:6px;color:oklch(0.30 0.02 255);background:oklch(1 0 0);box-shadow:0 1px 2px oklch(0.5 0.03 255/0.12);border:0;"

  defp segment_style(false),
    do:
      "font-size:12px;font-weight:500;padding:6px 14px;border-radius:6px;color:oklch(0.52 0.02 255);background:transparent;border:0;"

  # Valid values are nil ("no limit") or a positive integer (schemas require
  # `greater_than: 0`). Stepping below 1 clears the field to nil rather than landing on the
  # invalid 0 — returns "" (not nil) so the `phx-value-value` attribute isn't dropped from the
  # markup; `cast_node_value/2` and `cast_edge_value/2` already treat "" as nil.
  defp stepper_value(current, delta) do
    next = (current || 0) + delta
    if next < 1, do: "", else: next
  end
end
