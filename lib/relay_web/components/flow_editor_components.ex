defmodule RelayWeb.FlowEditorComponents do
  @moduledoc """
  Function components for `RelayWeb.FlowEditorLive`: the node/edge inspector panel, the
  ADD NODE palette, and the Connect edge / Delete toolbar buttons. Kept separate from the
  LiveView to keep it lean. Concrete visual values follow
  docs/designs/Relay Flow Editor.dc.html (§inspector lines ~127-202, palette ~466-476).
  """
  use RelayWeb, :html

  @type_tag %{
    agent:
      {"AGENT", "color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content))",
       "color-mix(in oklab, var(--color-secondary) 10%, var(--color-base-100))"},
    shell:
      {"SHELL", "color-mix(in oklab, var(--color-base-content) 70%, transparent)",
       "color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100))"},
    gate:
      {"GATE", "color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content))",
       "color-mix(in oklab, var(--color-warning) 15%, var(--color-base-100))"},
    parallel:
      {"PARALLEL", "color-mix(in oklab, var(--color-accent) 45%, var(--color-base-content))",
       "color-mix(in oklab, var(--color-accent) 15%, var(--color-base-100))"},
    human:
      {"HUMAN", "color-mix(in oklab, var(--color-primary) 55%, var(--color-base-content))",
       "color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100))"}
  }

  @palette_types [
    {:agent, "Agent", "var(--color-secondary)"},
    {:shell, "Shell", "color-mix(in oklab, var(--color-base-content) 60%, var(--color-base-100))"},
    {:gate, "Gate", "var(--color-warning)"},
    {:parallel, "Parallel", "var(--color-accent)"},
    {:human, "Human", "var(--color-primary)"}
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
        style="display:flex;align-items:center;gap:6px;background:var(--color-base-100);border:1px solid var(--color-field-border);color:color-mix(in oklab, var(--color-base-content) 85%, transparent);border-radius:8px;padding:6px 10px;font-size:12px;font-weight:600;"
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
      style="display:flex;align-items:center;gap:7px;background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 30%, var(--color-base-100));color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));border-radius:8px;padding:7px 12px;font-size:12.5px;font-weight:600;"
    >
      Delete
    </button>
    """
  end

  defp connect_button_style(true),
    do:
      "display:flex;align-items:center;gap:7px;background:color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-secondary) 45%, var(--color-base-100));color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));border-radius:8px;padding:7px 12px;font-size:12.5px;font-weight:600;"

  defp connect_button_style(false),
    do:
      "display:flex;align-items:center;gap:7px;background:var(--color-base-100);border:1px solid var(--color-field-border);color:color-mix(in oklab, var(--color-base-content) 80%, transparent);border-radius:8px;padding:7px 12px;font-size:12.5px;font-weight:600;"

  # ---- Node inspector ----

  attr :node, :map, required: true
  attr :edges, :list, required: true, doc: "the node's outgoing working-copy edges"
  attr :referenced_count, :integer, required: true
  attr :read_only?, :boolean, default: false

  def node_inspector(assigns) do
    assigns = assign(assigns, models: @models, efforts: @efforts)

    ~H"""
    <div>
      <div style="padding:16px 18px;border-bottom:1px solid var(--color-base-300);display:flex;flex-direction:column;gap:10px;">
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
          <.meta_label>
            NODE NAME
          </.meta_label>
          <form id="inspector-node-rename-form" phx-change="rename_node">
            <input type="hidden" name="key" value={@node.key} />
            <input
              id="inspector-node-name"
              name="value"
              type="text"
              value={@node.key}
              disabled={@read_only?}
              phx-debounce="blur"
              style="width:100%;padding:7px 9px;border:1px solid var(--color-field-border);border-radius:7px;font-size:15px;font-weight:600;color:var(--color-base-content);background:var(--color-field-bg);"
            />
          </form>
        </div>
        <div
          :if={@referenced_count > 0}
          id="inspector-delete-guard"
          style="display:flex;align-items:center;gap:7px;background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 25%, var(--color-base-100));border-radius:7px;padding:7px 9px;font-size:11px;color:color-mix(in oklab, var(--color-error) 65%, var(--color-base-content));"
        >
          <span style="font-weight:700;">⚠</span>
          Referenced by {@referenced_count} edge{if @referenced_count != 1, do: "s"} — clear them before deleting
        </div>
      </div>

      <div style="padding:16px 18px;display:flex;flex-direction:column;gap:18px;">
        <div style="display:flex;flex-direction:column;gap:7px;">
          <.meta_label>
            {main_label(@node.type)}
          </.meta_label>
          <form id="inspector-node-form" phx-change="edit_node_field">
            <input type="hidden" name="key" value={@node.key} />
            <input type="hidden" name="field" value="run" />
            <textarea
              name="value"
              disabled={@read_only?}
              style="width:100%;border:1px solid var(--color-field-border);background:var(--color-base-100);border-radius:8px;padding:10px 11px;font-size:12px;line-height:1.55;color:color-mix(in oklab, var(--color-base-content) 85%, transparent);font-family:ui-monospace,monospace;white-space:pre-wrap;min-height:96px;"
            >{@node.run}</textarea>
          </form>
        </div>

        <div :if={@node.type == :agent} style="display:flex;flex-direction:column;gap:8px;">
          <.meta_label>
            MODEL
          </.meta_label>
          <%!-- phx-value-v, not phx-value-value: "value" collides with the button's intrinsic
          DOM .value property (empty for a value-less <button>), which wins over the
          phx-value-* attribute when a real browser serializes the click — silently sending ""
          instead of the picked model. See board_live.ex's answer_select for the same fix. --%>
          <div style="display:flex;gap:6px;flex-wrap:wrap;">
            <button
              :for={model <- @models}
              id={"inspector-model-#{model}"}
              type="button"
              phx-click="edit_node_field"
              phx-value-key={@node.key}
              phx-value-field="model"
              phx-value-v={if model == "inherit", do: "", else: model}
              disabled={@read_only?}
              style={chip_style(model_selected?(@node, model))}
            >
              {model}
            </button>
          </div>
        </div>

        <div :if={@node.type == :agent} style="display:flex;flex-direction:column;gap:8px;">
          <.meta_label>
            EFFORT
          </.meta_label>
          <div style="display:inline-flex;background:color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100));border:1px solid var(--color-field-border);border-radius:9px;padding:3px;gap:2px;align-self:flex-start;">
            <button
              :for={effort <- @efforts}
              id={"inspector-effort-#{effort}"}
              type="button"
              phx-click="edit_node_field"
              phx-value-key={@node.key}
              phx-value-field="effort"
              phx-value-v={effort}
              disabled={@read_only?}
              style={segment_style(@node.effort == effort)}
            >
              {effort}
            </button>
          </div>
        </div>

        <div style="display:flex;gap:16px;">
          <div style="display:flex;flex-direction:column;gap:8px;">
            <.meta_label>
              MAX RETRIES
            </.meta_label>
            <div style="display:inline-flex;align-items:center;border:1px solid var(--color-field-border);border-radius:8px;overflow:hidden;align-self:flex-start;">
              <button
                id="inspector-max-retries-dec"
                type="button"
                phx-click="edit_node_field"
                phx-value-key={@node.key}
                phx-value-field="max_retries"
                phx-value-v={stepper_value(@node.max_retries, -1)}
                disabled={@read_only?}
                style="width:28px;height:34px;display:flex;align-items:center;justify-content:center;color:color-mix(in oklab, var(--color-base-content) 60%, transparent);font-size:16px;border:0;background:var(--color-base-100);"
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
                phx-value-v={stepper_value(@node.max_retries, 1)}
                disabled={@read_only?}
                style="width:28px;height:34px;display:flex;align-items:center;justify-content:center;color:color-mix(in oklab, var(--color-base-content) 60%, transparent);font-size:16px;border:0;background:var(--color-base-100);"
              >
                +
              </button>
            </div>
          </div>
          <div style="display:flex;flex-direction:column;gap:8px;flex:1;">
            <.meta_label>
              TIMEOUT (MIN)
            </.meta_label>
            <form id="inspector-node-timeout-form" phx-change="edit_node_field">
              <input type="hidden" name="key" value={@node.key} />
              <input type="hidden" name="field" value="timeout_minutes" />
              <input
                name="value"
                type="text"
                value={@node.timeout_minutes}
                disabled={@read_only?}
                style="width:100%;border:1px solid var(--color-field-border);border-radius:8px;padding:8px 11px;font-size:13px;font-family:ui-monospace,monospace;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);background:var(--color-field-bg);"
              />
            </form>
          </div>
        </div>

        <div
          :if={contract?(@node)}
          id="inspector-card-contract"
          style="display:flex;flex-direction:column;gap:7px;"
        >
          <.meta_label>
            CARD CONTRACT
          </.meta_label>
          <%!-- Display only (RE244): a declared `writes` is ENFORCED at run time, so authoring
          it belongs to `flow-push` + /relay-doctor's establish dialogue, never an inline
          control that could ship an aspirational declaration. --%>
          <div
            id="inspector-card-contract-value"
            style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;font-size:12px;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);"
          >
            <span :if={@node.reads != []}>reads</span>
            <span
              :if={@node.reads != []}
              style="font-family:ui-monospace,monospace;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"
            >
              {Enum.join(@node.reads, ", ")}
            </span>
            <span
              :if={@node.reads != [] and @node.writes != []}
              style="color:color-mix(in oklab, var(--color-base-content) 40%, transparent);"
            >
              ·
            </span>
            <span :if={@node.writes != []}>writes</span>
            <span
              :if={@node.writes != []}
              style="font-family:ui-monospace,monospace;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"
            >
              {Enum.join(@node.writes, ", ")}
            </span>
          </div>
        </div>

        <div style="display:flex;flex-direction:column;gap:9px;">
          <.meta_label>
            OUTGOING EDGES · routed on outcome
          </.meta_label>
          <div
            :for={edge <- @edges}
            style="display:flex;align-items:center;gap:8px;border:1px solid var(--color-base-300);border-radius:8px;padding:8px 10px;background:var(--color-base-200);"
          >
            <span style="font-size:10px;font-weight:600;font-family:ui-monospace,monospace;padding:2px 7px;border-radius:5px;background:color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100));color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
              {edge.on}
            </span>
            <span style="color:color-mix(in oklab, var(--color-base-content) 40%, transparent);font-size:11px;">
              →
            </span>
            <span style="font-size:12px;font-weight:500;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);flex:1;">
              {edge.to}
            </span>
            <span
              :if={edge.max_loops}
              style="font-size:9.5px;font-weight:600;font-family:ui-monospace,monospace;color:color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content));background:color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100));border-radius:4px;padding:2px 5px;"
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
    assigns = assign(assigns, outcomes: @outcomes, whens: Schemas.Flow.Edge.when_values())

    ~H"""
    <div style="padding:16px 18px;display:flex;flex-direction:column;gap:16px;">
      <div style="display:flex;align-items:center;gap:8px;">
        <.meta_label>
          EDGE
        </.meta_label>
        <span style="flex:1;"></span>
        <button
          id="inspector-delete-edge"
          type="button"
          phx-click="delete_selected"
          disabled={@read_only?}
          style="background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 25%, var(--color-base-100));color:color-mix(in oklab, var(--color-error) 80%, var(--color-base-content));border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;"
        >
          Delete edge
        </button>
      </div>

      <div style="display:flex;align-items:center;gap:8px;font-size:13px;font-weight:600;">
        <span
          id="inspector-edge-from"
          style="font-family:ui-monospace,monospace;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);"
        >
          {@edge.from}
        </span>
        <span style="color:color-mix(in oklab, var(--color-base-content) 40%, transparent);">→</span>
        <span
          id="inspector-edge-to"
          style="font-family:ui-monospace,monospace;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);"
        >
          {@edge.to}
        </span>
      </div>

      <div style="display:flex;flex-direction:column;gap:7px;">
        <.meta_label>
          OUTCOME
        </.meta_label>
        <form id="inspector-edge-outcome-form" phx-change="edit_edge">
          <input type="hidden" name="index" value={@index} />
          <input type="hidden" name="field" value="on" />
          <select
            name="value"
            disabled={@read_only?}
            style="border:1px solid var(--color-field-border);background:var(--color-field-bg);border-radius:8px;padding:6px 10px;font-size:12.5px;font-family:ui-monospace,monospace;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);"
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

      <div style="display:flex;flex-direction:column;gap:7px;">
        <.meta_label>
          WHEN
        </.meta_label>
        <form id="inspector-edge-when-form" phx-change="edit_edge">
          <input type="hidden" name="index" value={@index} />
          <input type="hidden" name="field" value="when" />
          <select
            id="inspector-edge-when"
            name="value"
            disabled={@read_only?}
            style="border:1px solid var(--color-field-border);background:var(--color-field-bg);border-radius:8px;padding:6px 10px;font-size:12.5px;font-family:ui-monospace,monospace;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);"
          >
            <option value="" selected={is_nil(@edge.when)}>(none)</option>
            <option
              :for={when_value <- @whens}
              value={when_value}
              selected={@edge.when == when_value}
            >
              {when_value}
            </option>
          </select>
        </form>
      </div>

      <div style="display:flex;flex-direction:column;gap:8px;">
        <.meta_label>
          MAX LOOPS
        </.meta_label>
        <div style="display:inline-flex;align-items:center;border:1px solid var(--color-field-border);border-radius:8px;overflow:hidden;align-self:flex-start;">
          <button
            id="inspector-max-loops-dec"
            type="button"
            phx-click="edit_edge"
            phx-value-index={@index}
            phx-value-field="max_loops"
            phx-value-v={stepper_value(@edge.max_loops, -1)}
            disabled={@read_only?}
            style="width:28px;height:34px;display:flex;align-items:center;justify-content:center;color:color-mix(in oklab, var(--color-base-content) 60%, transparent);font-size:16px;border:0;background:var(--color-base-100);"
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
            phx-value-v={stepper_value(@edge.max_loops, 1)}
            disabled={@read_only?}
            style="width:28px;height:34px;display:flex;align-items:center;justify-content:center;color:color-mix(in oklab, var(--color-base-content) 60%, transparent);font-size:16px;border:0;background:var(--color-base-100);"
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
      <.modal_scrim phx-click="close_modal" />
      <div style="position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);z-index:51;width:min(560px,92vw);max-height:80vh;overflow-y:auto;background:var(--color-base-100);border:1px solid var(--color-field-border);border-radius:16px;">
        <div style="padding:20px 22px;display:flex;flex-direction:column;gap:14px;">
          <span style="font-size:16px;font-weight:600;color:var(--color-base-content);">
            Diff vs shipped default
          </span>

          <div style="display:flex;flex-direction:column;gap:8px;font-family:ui-monospace,monospace;font-size:12px;">
            <div :if={@diff.nodes.added != []}>
              <div style="font-weight:600;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
                Nodes added
              </div>
              <div
                :for={key <- @diff.nodes.added}
                style="color:color-mix(in oklab, var(--color-success) 55%, var(--color-base-content));"
              >
                + {key}
              </div>
            </div>
            <div :if={@diff.nodes.removed != []}>
              <div style="font-weight:600;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
                Nodes removed
              </div>
              <div
                :for={key <- @diff.nodes.removed}
                style="color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));"
              >
                - {key}
              </div>
            </div>
            <div :if={@diff.nodes.changed != []}>
              <div style="font-weight:600;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
                Nodes changed
              </div>
              <div
                :for={c <- @diff.nodes.changed}
                style="color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));"
              >
                ~ {c.key} ({Enum.join(c.fields, ", ")})
              </div>
            </div>
            <div :if={@diff.edges.added != []}>
              <div style="font-weight:600;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
                Edges added
              </div>
              <div
                :for={{from, to, on} <- @diff.edges.added}
                style="color:color-mix(in oklab, var(--color-success) 55%, var(--color-base-content));"
              >
                + {from} → {to} on {on}
              </div>
            </div>
            <div :if={@diff.edges.removed != []}>
              <div style="font-weight:600;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
                Edges removed
              </div>
              <div
                :for={{from, to, on} <- @diff.edges.removed}
                style="color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));"
              >
                - {from} → {to} on {on}
              </div>
            </div>
          </div>
        </div>
        <div style="background:var(--color-base-200);border-top:1px solid var(--color-base-300);padding:14px 22px;display:flex;justify-content:flex-end;">
          <button
            type="button"
            phx-click="close_modal"
            style="background:var(--color-base-100);border:1px solid color-mix(in oklab, var(--color-base-content) 15%, var(--color-base-100));color:color-mix(in oklab, var(--color-base-content) 80%, transparent);border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;"
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
      <.modal_scrim phx-click="close_modal" />
      <div style="position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);z-index:51;width:min(480px,92vw);background:var(--color-base-100);border:1px solid var(--color-field-border);border-radius:16px;">
        <div style="padding:22px 24px;display:flex;flex-direction:column;gap:12px;">
          <span style="font-size:17px;font-weight:600;color:var(--color-base-content);">
            Reset the {@flow_name} flow to the shipped default?
          </span>
          <p style="font-size:13.5px;line-height:1.6;color:color-mix(in oklab, var(--color-base-content) 75%, transparent);">
            Replace this flow's definition with the shipped default? Your customizations are
            overwritten. The flow's triggers and on/off state are untouched.
          </p>
        </div>
        <div style="background:var(--color-base-200);border-top:1px solid var(--color-base-300);padding:14px 24px;display:flex;justify-content:flex-end;gap:9px;">
          <button
            type="button"
            phx-click="close_modal"
            style="background:var(--color-base-100);border:1px solid color-mix(in oklab, var(--color-base-content) 15%, var(--color-base-100));color:color-mix(in oklab, var(--color-base-content) 80%, transparent);border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;"
          >
            Cancel
          </button>
          <button
            id="flow-reset-confirm"
            type="button"
            phx-click="confirm_reset"
            style="background:var(--color-warning);color:var(--color-warning-content);border:none;border-radius:8px;padding:9px 18px;font-size:13px;font-weight:600;"
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
      "background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 25%, var(--color-base-100));color:color-mix(in oklab, var(--color-error) 80%, var(--color-base-content));border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;opacity:0.55;cursor:not-allowed;"

  defp delete_button_style(false),
    do:
      "background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 25%, var(--color-base-100));color:color-mix(in oklab, var(--color-error) 80%, var(--color-base-content));border-radius:7px;padding:6px 11px;font-size:12px;font-weight:600;"

  defp main_label(:shell), do: "COMMAND"
  defp main_label(:gate), do: "CONDITION"
  defp main_label(_), do: "RUN PROMPT"

  # Omitted entirely when the node declares neither, so today's undeclared flows look unchanged.
  defp contract?(node), do: node.reads != [] or node.writes != []

  defp model_selected?(%{model: nil}, "inherit"), do: true
  defp model_selected?(%{model: model}, model), do: true
  defp model_selected?(_, _), do: false

  defp chip_style(true),
    do:
      "font-size:12px;font-weight:600;padding:6px 12px;border-radius:7px;border:1px solid var(--color-secondary);background:color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100));color:color-mix(in oklab, var(--color-secondary) 60%, var(--color-base-content));font-family:ui-monospace,monospace;"

  defp chip_style(false),
    do:
      "font-size:12px;font-weight:600;padding:6px 12px;border-radius:7px;border:1px solid var(--color-field-border);background:var(--color-base-100);color:color-mix(in oklab, var(--color-base-content) 75%, transparent);font-family:ui-monospace,monospace;"

  defp segment_style(true),
    do:
      "font-size:12px;font-weight:600;padding:6px 14px;border-radius:6px;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);background:var(--color-base-100);box-shadow:0 1px 2px color-mix(in oklab, var(--color-base-content) 12%, transparent);border:0;"

  defp segment_style(false),
    do:
      "font-size:12px;font-weight:500;padding:6px 14px;border-radius:6px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);background:transparent;border:0;"

  # Valid values are nil ("no limit") or a positive integer (schemas require
  # `greater_than: 0`). Stepping below 1 clears the field to nil rather than landing on the
  # invalid 0 — returns "" (not nil) so the `phx-value-v` attribute isn't dropped from the
  # markup; `cast_node_value/2` and `cast_edge_value/2` already treat "" as nil.
  defp stepper_value(current, delta) do
    next = (current || 0) + delta
    if next < 1, do: "", else: next
  end

  attr :board_slug, :string, required: true
  attr :flow_key, :string, required: true
  attr :active, :atom, values: [:editor, :metrics], required: true

  @doc "Editor | Metrics tab strip shared by FlowEditorLive and FlowMetricsLive."
  def flow_tabs(assigns) do
    ~H"""
    <nav id="flow-tabs" style="display:flex;align-items:center;gap:2px;">
      <.link
        id="flow-tab-editor"
        navigate={~p"/board/#{@board_slug}/flows/#{@flow_key}"}
        style={flow_tab_style(@active == :editor)}
      >
        Editor
      </.link>
      <.link
        id="flow-tab-metrics"
        navigate={~p"/board/#{@board_slug}/flows/#{@flow_key}/metrics"}
        style={flow_tab_style(@active == :metrics)}
      >
        Metrics
      </.link>
    </nav>
    """
  end

  defp flow_tab_style(true),
    do:
      "font-size:13px;font-weight:600;padding:5px 12px;border-radius:7px;" <>
        "background:var(--color-base-100);color:color-mix(in oklab, var(--color-base-content) 95%, transparent);box-shadow:0 1px 2px color-mix(in oklab, var(--color-base-content) 14%, transparent);"

  defp flow_tab_style(false),
    do:
      "font-size:13px;font-weight:600;padding:5px 12px;border-radius:7px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
end
