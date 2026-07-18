defmodule RelayWeb.FlowSettingsComponents do
  @moduledoc """
  Function components for the board settings **Flows** pane (RLY-142),
  matching `docs/designs/Relay Flows.dc.html`. Page-specific — no storybook
  entry; all events live on `RelayWeb.BoardSettingsLive`. Recorded artboard
  deviations (no "+ New flow" button, no VERSION column until RLY-152,
  kebab-carried origin, inlined cutover ritual, engine note) are pinned in
  the card's spec.
  """

  use Phoenix.Component

  alias Schemas.Flow

  @doc ~S|Humanized flow name: "spec" → "Spec", "spec-copy" → "Spec copy".|
  def flow_name(%Flow{key: key}), do: key |> String.replace("-", " ") |> String.capitalize()

  attr :rows, :list, required: true, doc: "%{flow: %Flow{}, customized?: bool, resettable?: bool} maps"
  attr :panel, :any, required: true, doc: "nil | {flow_id, :confirm}"

  def flows_pane(assigns) do
    ~H"""
    <section id="flows-pane">
      <h1 style="font-size:22px;font-weight:600;letter-spacing:-0.02em;margin:0 0 6px 0;color:oklch(0.26 0.02 255);">
        Flows
      </h1>
      <%!-- Artboard blurb minus the versioning sentence (deferred to RLY-152). --%>
      <p style="font-size:14px;line-height:1.55;color:oklch(0.50 0.02 255);margin:0;max-width:600px;">
        A flow is the automation attached to a stage transition — it pulls work from one
        stage, runs a graph of agent and shell steps, and lands the card on the next stage
        when it succeeds.
      </p>

      <div
        :if={@rows == []}
        id="flows-empty"
        style="margin-top:22px;border:1px dashed oklch(0.86 0.01 255);border-radius:12px;background:oklch(1 0 0);padding:26px 24px;font-size:13.5px;line-height:1.6;color:oklch(0.50 0.02 255);max-width:640px;"
      >
        No flows on this board yet. Default flows are seeded when a board is created;
        existing boards get them with the Spec-flow cutover (RLY-136).
      </div>

      <%= if @rows != [] do %>
        <.first_run_banner :if={Enum.all?(@rows, &(not &1.flow.enabled))} rows={@rows} />
        <.legend />
        <.flows_table rows={@rows} panel={@panel} />
        <p
          id="flows-footer-note"
          style="font-size:12px;line-height:1.55;color:oklch(0.58 0.02 255);margin:16px 2px 0 2px;max-width:640px;"
        >
          Disabling a flow is a cutover — cards stop being picked up at that transition and
          wait for a human. Enabling one starts handing new cards to the AI immediately.
        </p>
        <p
          id="flows-engine-note"
          style="font-size:12px;line-height:1.55;color:oklch(0.62 0.02 255);margin:6px 2px 0 2px;max-width:640px;"
        >
          The flow engine isn't dispatching yet: this switch records intent; server-side
          dispatch arrives with the scheduler (RLY-133).
        </p>
      <% end %>
    </section>
    """
  end

  attr :rows, :list, required: true

  defp first_run_banner(assigns) do
    ~H"""
    <div
      id="flows-first-run"
      style="display:flex;align-items:flex-start;gap:12px;background:oklch(0.98 0.02 250);border:1px solid oklch(0.89 0.05 250);border-radius:12px;padding:15px 17px;margin-top:20px;"
    >
      <span style="width:24px;height:24px;border-radius:7px;background:oklch(0.60 0.14 250);color:oklch(1 0 0);display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;flex:0 0 auto;">
        i
      </span>
      <div style="flex:1;">
        <div style="font-size:14px;font-weight:600;color:oklch(0.34 0.10 250);margin-bottom:3px;">
          Flows are off until you turn them on
        </div>
        <p style="font-size:13px;line-height:1.55;color:oklch(0.44 0.04 250);margin:0;max-width:620px;">
          This board ships with the {flow_names(@rows)} defaults, but nothing runs
          automatically yet — every card waits for a human. Turn a flow on to start handing
          its stage to the AI. Cut over one flow at a time; you can always turn it back off.
        </p>
      </div>
    </div>
    """
  end

  defp legend(assigns) do
    ~H"""
    <div
      id="flows-legend"
      class="font-mono"
      style="display:flex;gap:18px;flex-wrap:wrap;margin:22px 0 12px 0;font-size:11px;color:oklch(0.55 0.02 255);"
    >
      <span style="display:flex;align-items:center;gap:6px;">
        <span style="width:8px;height:8px;border-radius:2px;background:oklch(0.62 0.13 195);"></span>
        shared_clean — many runs, fresh checkout each
      </span>
      <span style="display:flex;align-items:center;gap:6px;">
        <span style="width:8px;height:8px;border-radius:2px;background:oklch(0.70 0.13 65);"></span>
        exclusive — one run per machine, holds the tree
      </span>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :panel, :any, required: true

  defp flows_table(assigns) do
    ~H"""
    <div
      id="flows-table"
      style="border:1px solid oklch(0.92 0.006 255);border-radius:12px;overflow:hidden;background:oklch(1 0 0);box-shadow:0 1px 2px oklch(0.55 0.03 255/0.04);"
    >
      <div style="overflow-x:auto;">
        <div style="min-width:660px;">
          <div
            class="font-mono"
            style="display:flex;align-items:center;gap:14px;padding:11px 18px;background:oklch(0.975 0.004 255);border-bottom:1px solid oklch(0.93 0.006 255);font-size:10.5px;font-weight:600;letter-spacing:0.06em;color:oklch(0.55 0.02 255);"
          >
            <span style="flex:0 0 150px;">FLOW</span>
            <span style="flex:1;min-width:0;white-space:nowrap;">
              TRIGGER · pulls / works / lands
            </span>
            <span style="flex:0 0 108px;">ISOLATION</span>
            <span style="flex:0 0 60px;text-align:center;">ON</span>
            <span style="flex:0 0 34px;"></span>
          </div>

          <div :for={row <- @rows} style="border-bottom:1px solid oklch(0.95 0.005 255);">
            <div id={"flow-row-#{row.flow.id}"} style={row_style(row.flow.enabled)}>
              <div style="flex:0 0 150px;display:flex;flex-direction:column;gap:3px;min-width:0;">
                <span style="font-size:14px;font-weight:600;color:oklch(0.26 0.02 255);letter-spacing:-0.01em;">
                  {flow_name(row.flow)}
                </span>
                <span
                  class="font-mono"
                  style="display:flex;align-items:center;gap:8px;font-size:11px;color:oklch(0.60 0.02 255);"
                >
                  <span id={"flow-#{row.flow.id}-nodes-count"}>{nodes_label(row.flow)}</span>
                  <span
                    :if={row.customized?}
                    id={"flow-#{row.flow.id}-customized"}
                    style="font-size:9px;font-weight:600;letter-spacing:0.05em;color:oklch(0.46 0.12 250);background:oklch(0.96 0.03 250);padding:2px 6px;border-radius:4px;"
                  >
                    customized
                  </span>
                </span>
              </div>

              <div
                id={"flow-#{row.flow.id}-trigger"}
                style="flex:1;min-width:0;display:flex;flex-wrap:wrap;align-items:center;gap:6px;row-gap:4px;"
              >
                <.stage_chip stage={row.flow.pulls_from_stage} style={chip_style(:pulls)} />
                <span style="color:oklch(0.72 0.02 255);font-size:12px;">→</span>
                <.stage_chip stage={row.flow.works_in_stage} style={chip_style(:works)} />
                <span style="color:oklch(0.72 0.02 255);font-size:12px;">→</span>
                <.stage_chip stage={row.flow.lands_on_stage} style={chip_style(:lands)} />
              </div>

              <div style="flex:0 0 108px;">
                <span
                  id={"flow-#{row.flow.id}-isolation"}
                  class="font-mono"
                  style={iso_style(row.flow.isolation, row.flow.enabled)}
                >
                  <span style={iso_dot(row.flow.isolation)}></span>{row.flow.isolation}
                </span>
              </div>

              <div style="flex:0 0 60px;display:flex;justify-content:center;">
                <button
                  type="button"
                  id={"flow-#{row.flow.id}-toggle"}
                  phx-click="flow_toggle"
                  phx-value-flow-id={row.flow.id}
                  aria-pressed={to_string(row.flow.enabled)}
                  aria-label={"Toggle the #{flow_name(row.flow)} flow"}
                  disabled={trigger_missing?(row.flow)}
                  title={
                    if(trigger_missing?(row.flow),
                      do: "A trigger stage is missing — set it before enabling this flow",
                      else: nil
                    )
                  }
                  style={toggle_style(row.flow.enabled, trigger_missing?(row.flow))}
                >
                  <span style={knob_style(row.flow.enabled)}></span>
                </button>
              </div>

              <div style="flex:0 0 34px;display:flex;justify-content:flex-end;">
                <details class="dropdown dropdown-end" id={"flow-#{row.flow.id}-menu"}>
                  <summary
                    aria-label={"Actions for the #{flow_name(row.flow)} flow"}
                    style="list-style:none;width:28px;height:28px;border-radius:7px;border:1px solid oklch(0.92 0.006 255);background:oklch(1 0 0);color:oklch(0.50 0.02 255);display:flex;align-items:center;justify-content:center;font-size:15px;line-height:1;cursor:pointer;"
                  >
                    ⋯
                  </summary>
                  <ul class="menu dropdown-content z-10 w-48 rounded-box bg-base-100 p-1 shadow">
                    <li>
                      <button
                        type="button"
                        id={"flow-#{row.flow.id}-edit"}
                        phx-click="flow_open_definition"
                        phx-value-flow-id={row.flow.id}
                      >
                        ✎ Edit flow
                      </button>
                    </li>
                    <li>
                      <button
                        type="button"
                        id={"flow-#{row.flow.id}-duplicate"}
                        phx-click="flow_duplicate"
                        phx-value-flow-id={row.flow.id}
                      >
                        ⧉ Duplicate
                      </button>
                    </li>
                    <li :if={row.resettable?}>
                      <button
                        type="button"
                        id={"flow-#{row.flow.id}-reset"}
                        phx-click="flow_reset"
                        phx-value-flow-id={row.flow.id}
                      >
                        ↺ Reset to default
                      </button>
                    </li>
                  </ul>
                </details>
              </div>
            </div>

            <.toggle_confirm :if={@panel == {row.flow.id, :confirm}} flow={row.flow} />
            <.definition_panel :if={@panel == {row.flow.id, :definition}} flow={row.flow} />
            <.reset_confirm :if={@panel == {row.flow.id, :reset}} flow={row.flow} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :flow, Flow, required: true

  defp toggle_confirm(assigns) do
    ~H"""
    <div
      id={"flow-#{@flow.id}-confirm"}
      style="display:flex;align-items:flex-start;gap:12px;margin:0 18px 16px 18px;background:oklch(0.985 0.025 75);border:1px solid oklch(0.87 0.07 75);border-radius:10px;padding:14px 16px;"
    >
      <span style="width:22px;height:22px;border-radius:50%;background:oklch(0.70 0.13 65);color:oklch(1 0 0);display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;flex:0 0 auto;">
        !
      </span>
      <div style="flex:1;">
        <div style="font-size:13.5px;font-weight:600;color:oklch(0.42 0.10 65);margin-bottom:3px;">
          {confirm_title(@flow)}
        </div>
        <p style="font-size:12.5px;line-height:1.5;color:oklch(0.44 0.05 65);margin:0 0 12px 0;max-width:560px;">
          {confirm_body(@flow)}
        </p>
        <div style="display:flex;gap:8px;">
          <button
            type="button"
            id={"flow-#{@flow.id}-confirm-cta"}
            phx-click="flow_confirm_toggle"
            phx-value-flow-id={@flow.id}
            style="background:oklch(0.62 0.14 65);color:oklch(1 0 0);border:none;border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
          >
            {confirm_cta(@flow)}
          </button>
          <button
            type="button"
            id={"flow-#{@flow.id}-confirm-cancel"}
            phx-click="flow_cancel_panel"
            style="background:oklch(1 0 0);border:1px solid oklch(0.88 0.04 65);color:oklch(0.48 0.04 65);border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :stage, :any, required: true, doc: "a preloaded %Schemas.Stage{} or nil (missing trigger)"
  attr :style, :string, required: true

  defp stage_chip(%{stage: nil} = assigns) do
    ~H"""
    <span class="font-mono" style={chip_style(:missing)}>missing stage</span>
    """
  end

  defp stage_chip(assigns) do
    ~H"""
    <span class="font-mono" style={@style}>{@stage.name}</span>
    """
  end

  defp confirm_title(%Flow{enabled: false} = flow), do: "Turn on the #{flow_name(flow)} flow?"
  defp confirm_title(%Flow{} = flow), do: "Turn off the #{flow_name(flow)} flow?"

  # Enable body = the artboard's behavioral line (minus the version phrase,
  # RLY-152) + the inlined double-dispatch cutover ritual (spec interview #3).
  defp confirm_body(%Flow{enabled: false} = flow) do
    "New cards reaching #{pulls_name(flow)} will be handed to the AI automatically. " <>
      "Cards already sitting there won't move until you say so. Before turning this on, " <>
      "make sure the legacy watcher no longer serves this stage: stop bin/relay watch, " <>
      "remove this stage's entry from relay_config.json, and restart it. While both are " <>
      "configured, the old watcher and the server engine will race for the same cards " <>
      "(double dispatch)."
  end

  defp confirm_body(%Flow{} = flow) do
    "Cards reaching #{pulls_name(flow)} will stop being picked up and wait for a human " <>
      "instead. Runs already in flight finish normally. To hand the stage back to the " <>
      "legacy watcher, re-add this stage's entry to relay_config.json and restart it."
  end

  defp confirm_cta(%Flow{enabled: false} = flow), do: "Turn on #{flow_name(flow)}"
  defp confirm_cta(%Flow{} = flow), do: "Turn off #{flow_name(flow)}"

  # The confirm is unreachable when the pulls-from trigger is nil (the toggle
  # is disabled), but stay total for arbitrary data.
  defp pulls_name(%Flow{pulls_from_stage: %{name: name}}), do: name
  defp pulls_name(%Flow{}), do: "its pulls-from stage"

  defp trigger_missing?(%Flow{} = flow) do
    is_nil(flow.pulls_from_stage_id) or is_nil(flow.works_in_stage_id) or
      is_nil(flow.lands_on_stage_id)
  end

  defp flow_names(rows) do
    case Enum.map(rows, &flow_name(&1.flow)) do
      [one] -> one
      names -> Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)
    end
  end

  defp nodes_label(%Flow{nodes: [_single]}), do: "1 node"
  defp nodes_label(%Flow{nodes: nodes}), do: "#{length(nodes)} nodes"

  defp row_style(enabled?) do
    "display:flex;align-items:center;gap:14px;padding:14px 18px;" <>
      if(enabled?, do: "", else: "background:oklch(0.992 0.002 255);")
  end

  @chip_base "font-size:11.5px;font-weight:500;border-radius:6px;padding:4px 9px;white-space:nowrap;"

  defp chip_style(:pulls),
    do:
      @chip_base <> "color:oklch(0.50 0.02 255);background:oklch(0.965 0.004 255);border:1px solid oklch(0.92 0.006 255);"

  defp chip_style(:works),
    do: @chip_base <> "color:oklch(0.46 0.14 292);background:oklch(0.98 0.03 292);border:1px solid oklch(0.91 0.05 292);"

  defp chip_style(:lands),
    do: @chip_base <> "color:oklch(0.44 0.13 250);background:oklch(0.98 0.012 250);border:1px solid oklch(0.91 0.03 250);"

  defp chip_style(:missing),
    do: @chip_base <> "color:oklch(0.48 0.11 65);background:oklch(0.98 0.04 75);border:1px solid oklch(0.87 0.07 75);"

  defp iso_style(isolation, enabled?) do
    "display:inline-flex;align-items:center;gap:6px;font-size:10.5px;font-weight:600;padding:3px 8px;border-radius:6px;" <>
      case isolation do
        :shared_clean -> "background:oklch(0.97 0.03 195);color:oklch(0.42 0.10 195);"
        :exclusive -> "background:oklch(0.98 0.04 75);color:oklch(0.48 0.11 65);"
      end <>
      if(enabled?, do: "", else: "opacity:0.55;")
  end

  defp iso_dot(:shared_clean), do: "width:6px;height:6px;border-radius:2px;background:oklch(0.62 0.13 195);"
  defp iso_dot(:exclusive), do: "width:6px;height:6px;border-radius:2px;background:oklch(0.70 0.13 65);"

  defp toggle_style(enabled?, missing?) do
    "width:38px;height:22px;border-radius:11px;position:relative;transition:background 0.18s;border:none;padding:0;" <>
      if(enabled?, do: "background:oklch(0.60 0.14 250);", else: "background:oklch(0.88 0.01 255);") <>
      if(missing?, do: "opacity:0.45;cursor:not-allowed;", else: "cursor:pointer;")
  end

  defp knob_style(enabled?) do
    "position:absolute;top:2px;" <>
      if(enabled?, do: "right:2px;", else: "left:2px;") <>
      "width:18px;height:18px;border-radius:50%;background:oklch(1 0 0);transition:all 0.18s;box-shadow:0 1px 2px oklch(0.4 0.02 255/0.3);"
  end

  attr :flow, Flow, required: true

  # Read-only structured text (spec interview #2) — the real editor is RLY-143.
  defp definition_panel(assigns) do
    ~H"""
    <div
      id={"flow-#{@flow.id}-definition"}
      style="margin:0 18px 16px 18px;background:oklch(0.985 0.004 255);border:1px solid oklch(0.92 0.006 255);border-radius:10px;padding:14px 16px;"
    >
      <div
        class="font-mono"
        style="font-size:10.5px;font-weight:600;letter-spacing:0.06em;color:oklch(0.55 0.02 255);margin-bottom:8px;"
      >
        NODES
      </div>
      <div style="display:flex;flex-direction:column;gap:4px;">
        <div
          :for={node <- @flow.nodes}
          id={"flow-#{@flow.id}-node-#{node.key}"}
          class="font-mono"
          style="font-size:12px;line-height:1.5;color:oklch(0.38 0.02 255);"
        >
          <span style="font-weight:600;">{node.key}</span>
          <span style="color:oklch(0.58 0.02 255);"> ·        {node.type}{node_meta(node)}</span>
          <span :if={node.run} style="color:oklch(0.50 0.02 255);"> —        {node.run}</span>
        </div>
      </div>
      <div
        class="font-mono"
        style="font-size:10.5px;font-weight:600;letter-spacing:0.06em;color:oklch(0.55 0.02 255);margin:12px 0 8px 0;"
      >
        EDGES
      </div>
      <div style="display:flex;flex-direction:column;gap:4px;">
        <div
          :for={{edge, index} <- Enum.with_index(@flow.edges)}
          id={"flow-#{@flow.id}-edge-#{index}"}
          class="font-mono"
          style="font-size:12px;line-height:1.5;color:oklch(0.38 0.02 255);"
        >
          {edge_line(edge)}
        </div>
      </div>
      <p
        id={"flow-#{@flow.id}-definition-note"}
        style="font-size:11.5px;color:oklch(0.58 0.02 255);margin:12px 0 0 0;"
      >
        Editing arrives with the flow editor (RLY-143).
      </p>
    </div>
    """
  end

  attr :flow, Flow, required: true

  defp reset_confirm(assigns) do
    ~H"""
    <div
      id={"flow-#{@flow.id}-reset-confirm"}
      style="display:flex;align-items:flex-start;gap:12px;margin:0 18px 16px 18px;background:oklch(0.985 0.025 75);border:1px solid oklch(0.87 0.07 75);border-radius:10px;padding:14px 16px;"
    >
      <span style="width:22px;height:22px;border-radius:50%;background:oklch(0.70 0.13 65);color:oklch(1 0 0);display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;flex:0 0 auto;">
        !
      </span>
      <div style="flex:1;">
        <div style="font-size:13.5px;font-weight:600;color:oklch(0.42 0.10 65);margin-bottom:3px;">
          Reset the {flow_name(@flow)} flow to the shipped default?
        </div>
        <p style="font-size:12.5px;line-height:1.5;color:oklch(0.44 0.05 65);margin:0 0 12px 0;max-width:560px;">
          Replace this flow's definition with the shipped default? Your customizations are
          overwritten. The flow's triggers and on/off state are untouched.
        </p>
        <div style="display:flex;gap:8px;">
          <button
            type="button"
            id={"flow-#{@flow.id}-reset-cta"}
            phx-click="flow_confirm_reset"
            phx-value-flow-id={@flow.id}
            style="background:oklch(0.62 0.14 65);color:oklch(1 0 0);border:none;border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
          >
            Reset {flow_name(@flow)}
          </button>
          <button
            type="button"
            id={"flow-#{@flow.id}-reset-cancel"}
            phx-click="flow_cancel_panel"
            style="background:oklch(1 0 0);border:1px solid oklch(0.88 0.04 65);color:oklch(0.48 0.04 65);border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  # " · sonnet/high · retries 3" — only the parts that are set.
  defp node_meta(node) do
    model_effort =
      case Enum.reject([node.model, node.effort], &is_nil/1) do
        [] -> ""
        parts -> " · " <> Enum.join(parts, "/")
      end

    retries = if node.max_retries, do: " · retries #{node.max_retries}", else: ""
    model_effort <> retries
  end

  defp edge_line(edge) do
    on = if edge.on, do: " on #{edge.on}", else: ""
    loops = if edge.max_loops, do: " (max_loops #{edge.max_loops})", else: ""
    "#{edge.from} → #{edge.to}#{on}#{loops}"
  end
end
