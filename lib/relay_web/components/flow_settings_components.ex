defmodule RelayWeb.FlowSettingsComponents do
  @moduledoc """
  Function components for the board settings **Flows** pane (RLY-142),
  matching `docs/designs/Relay Flows.dc.html`. Page-specific — no storybook
  entry; all events live on `RelayWeb.BoardSettingsLive`. Recorded artboard
  deviations (kebab-carried origin, inlined cutover ritual, and the
  mockup-only Configured/First-run state switcher) are pinned in the card's spec.
  The artboard's "+ New flow" button ships as of RLY-158. Editing a flow's
  definition now navigates to the full-page editor (`RelayWeb.FlowEditorLive`,
  RLY-143); the row meta line shows the current version.

  The first-run explainer names only the flows Relay ships (`Flows.default_key?/1`), never
  every row on the board (RLY-160).
  """

  use RelayWeb, :html

  alias Relay.Flows
  alias Schemas.Flow

  @doc ~S|Humanized flow name: "spec" → "Spec", "spec-copy" → "Spec copy".|
  def flow_name(%Flow{key: key}), do: key |> String.replace("-", " ") |> String.capitalize()

  attr :rows, :list, required: true, doc: "%{flow: %Flow{}, customized?: bool, resettable?: bool} maps"
  attr :panel, :any, required: true, doc: "nil | {flow_id, :confirm} | {flow_id, :reset} | {:new, form}"
  attr :preflight, :any, default: nil, doc: "Runs.preflight_flow/1's snapshot for the open enable confirm, or nil"
  attr :slug, :string, required: true, doc: "the board slug, for the Edit item's editor link"
  attr :stages, :list, required: true, doc: "the board's stages, unfiltered, for the create form's pickers"
  attr :read_only?, :boolean, required: true, doc: "archived board — hides the create affordance"

  def flows_pane(assigns) do
    ~H"""
    <section id="flows-pane">
      <%!-- Mirrors the board view's read-only banner (board_live.ex:109-124): the
            "+ New flow" button is silently absent for an archived board, so state why. --%>
      <div
        :if={@read_only?}
        id="flows-read-only-banner"
        style="display:flex;align-items:center;gap:10px;background:oklch(0.97 0.04 85);border:1px solid oklch(0.85 0.09 85);color:oklch(0.42 0.09 85);border-radius:10px;padding:11px 16px;margin-bottom:18px;font-size:13.5px;"
      >
        <.icon name="hero-archive-box" class="size-4" />
        <span>This board is archived (read-only). Flows can't be created or changed.</span>
      </div>

      <%!-- Artboard lines 63-76: header is a flex row with the create button in a
            right-hand column. The artboard's Configured/First-run state switcher above
            the button is a mockup-only affordance and is deliberately not shipped. --%>
      <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:20px;">
        <div>
          <h1 style="font-size:22px;font-weight:600;letter-spacing:-0.02em;margin:0 0 6px 0;color:oklch(0.26 0.02 255);">
            Flows
          </h1>
          <%!-- Artboard blurb minus the versioning sentence (deferred to RLY-152). --%>
          <p style="font-size:14px;line-height:1.55;color:oklch(0.50 0.02 255);margin:0;max-width:600px;">
            A flow is the automation attached to a stage transition — it pulls work from one
            stage, runs a graph of agent and shell steps, and lands the card on the next stage
            when it succeeds.
          </p>
        </div>
        <div
          :if={!@read_only?}
          id="flows-header-actions"
          style="display:flex;flex-direction:column;align-items:flex-end;gap:10px;flex:0 0 auto;margin-top:4px;"
        >
          <button
            type="button"
            id="new-flow-button"
            phx-click="flow_new"
            style="display:flex;align-items:center;gap:6px;background:oklch(0.60 0.14 250);color:oklch(1 0 0);border:none;border-radius:8px;padding:9px 15px;font-size:13px;font-weight:600;"
          >
            <span style="font-size:15px;line-height:1;">+</span>New flow
          </button>
        </div>
      </div>

      <.new_flow_panel :if={new_form(@panel)} form={new_form(@panel)} stages={@stages} />

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
        <.flows_table rows={@rows} panel={@panel} preflight={@preflight} slug={@slug} />
        <p
          id="flows-footer-note"
          style="font-size:12px;line-height:1.55;color:oklch(0.58 0.02 255);margin:16px 2px 0 2px;max-width:640px;"
        >
          Disabling a flow is a cutover — cards stop being picked up at that transition and
          wait for a human. Enabling one starts handing new cards to the AI immediately.
        </p>
      <% end %>
    </section>
    """
  end

  # @panel's create variant carries the form itself; the row-keyed :confirm/:reset
  # variants are tuples whose first element is an integer id, so they never collide.
  defp new_form({:new, form}), do: form
  defp new_form(_panel), do: nil

  attr :form, :any, required: true
  attr :stages, :list, required: true

  defp new_flow_panel(assigns) do
    ~H"""
    <div
      id="new-flow-panel"
      style="margin:20px 0 4px 0;background:oklch(1 0 0);border:1px solid oklch(0.91 0.03 250);border-radius:12px;padding:14px 16px;max-width:640px;"
    >
      <div style="font-size:13.5px;font-weight:600;color:oklch(0.34 0.10 250);margin-bottom:3px;">
        New flow
      </div>
      <p style="font-size:12.5px;line-height:1.5;color:oklch(0.44 0.04 250);margin:0 0 12px 0;">
        Pick a key and the three stages this flow triggers on. It is created switched off with
        an empty graph — add its steps in the editor, then turn it on here.
      </p>
      <.form
        for={@form}
        id="new-flow-form"
        phx-submit="flow_create"
        phx-change="flow_create_validate"
      >
        <.input
          field={@form[:key]}
          type="text"
          id="new-flow-key"
          label="Key"
          placeholder="deploy-gate"
        />
        <.input
          field={@form[:pulls_from_stage_id]}
          type="select"
          id="new-flow-pulls-from"
          label="PULLS FROM"
          prompt="—"
          options={stage_options(@stages)}
        />
        <.input
          field={@form[:works_in_stage_id]}
          type="select"
          id="new-flow-works-in"
          label="WORKS IN"
          prompt="—"
          options={stage_options(@stages)}
        />
        <.input
          field={@form[:lands_on_stage_id]}
          type="select"
          id="new-flow-lands-on"
          label="LANDS ON SUCCESS"
          prompt="—"
          options={stage_options(@stages)}
        />
        <.input
          field={@form[:isolation]}
          type="select"
          id="new-flow-isolation"
          label="Isolation"
          options={[{"Shared clean", "shared_clean"}, {"Exclusive", "exclusive"}]}
        />
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button
            type="submit"
            id="new-flow-create"
            style="background:oklch(0.60 0.14 250);color:oklch(1 0 0);border:none;border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
          >
            Create flow
          </button>
          <button
            type="button"
            id="new-flow-cancel"
            phx-click="flow_cancel_panel"
            style="background:oklch(1 0 0);border:1px solid oklch(0.90 0.006 255);color:oklch(0.48 0.02 255);border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
          >
            Cancel
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp stage_options(stages), do: Enum.map(stages, &{&1.name, &1.id})

  attr :rows, :list, required: true

  defp first_run_banner(assigns) do
    assigns =
      assign(assigns, :shipped_rows, Enum.filter(assigns.rows, &Flows.default_key?(&1.flow.key)))

    ~H"""
    <div
      :if={@shipped_rows != []}
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
          This board ships with the {flow_names(@shipped_rows)} defaults, but nothing runs
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
  attr :preflight, :any, default: nil, doc: "Runs.preflight_flow/1's snapshot for the open enable confirm, or nil"
  attr :slug, :string, required: true

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
                  <span id={"flow-#{row.flow.id}-nodes-count"}>
                    v{row.flow.version} · {nodes_label(row.flow)}
                  </span>
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
                      <.link
                        navigate={~p"/board/#{@slug}/flows/#{row.flow.key}"}
                        id={"flow-#{row.flow.id}-edit"}
                      >
                        ✎ Edit flow
                      </.link>
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

            <.toggle_confirm
              :if={@panel == {row.flow.id, :confirm}}
              flow={row.flow}
              preflight={@preflight}
            />
            <.reset_confirm :if={@panel == {row.flow.id, :reset}} flow={row.flow} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :flow, Flow, required: true
  attr :preflight, :any, default: nil

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
        <p style="font-size:12.5px;line-height:1.5;color:oklch(0.44 0.05 65);margin:0 0 10px 0;max-width:560px;">
          {confirm_body(@flow)}
        </p>
        <.preflight_list :if={@preflight} flow={@flow} preflight={@preflight} />
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

  attr :flow, Flow, required: true
  attr :preflight, :map, required: true

  # Reports, never blocks: the confirm CTA above stays live in every state a row can show.
  defp preflight_list(assigns) do
    assigns = assign(assigns, :rows, preflight_rows(assigns.flow, assigns.preflight))

    ~H"""
    <ul
      id={"flow-#{@flow.id}-preflight"}
      style="list-style:none;margin:0 0 12px 0;padding:0;display:flex;flex-direction:column;gap:5px;max-width:560px;"
    >
      <li
        :for={row <- @rows}
        id={row.id}
        class={if row.ok?, do: "preflight-ok", else: "preflight-warn"}
        style="display:flex;align-items:flex-start;gap:7px;font-size:12.5px;line-height:1.45;"
      >
        <.icon
          name={if row.ok?, do: "hero-check-circle", else: "hero-exclamation-triangle"}
          class={["w-4 h-4 shrink-0 mt-px", if(row.ok?, do: "text-success", else: "text-warning")]}
        />
        <span style="color:oklch(0.42 0.04 65);">{row.text}</span>
      </li>
    </ul>
    """
  end

  # Pure: preflight map → the rendered rows, in a fixed order so the banner reads the same
  # every time. Each row's id is stable and is what the LiveView tests assert on.
  defp preflight_rows(flow, preflight) do
    [
      stages_row(flow, preflight),
      executor_row(flow, preflight),
      capacity_row(flow, preflight),
      names_row(flow, preflight, :agents),
      names_row(flow, preflight, :skills)
    ] ++ unreported_rows(flow, preflight)
  end

  defp row(flow, check, ok?, text), do: %{id: "flow-#{flow.id}-preflight-#{check}", ok?: ok?, text: text}

  defp stages_row(flow, %{stages: :ok}),
    do: row(flow, "stages", true, "All three trigger stages still exist on this board.")

  defp stages_row(flow, %{stages: {:missing, keys}}) do
    names = Enum.map_join(keys, ", ", &String.replace(Atom.to_string(&1), "_", "-"))
    row(flow, "stages", false, "Missing trigger stage: #{names}. The flow can't dispatch until it's set.")
  end

  defp executor_row(flow, %{executors: :none_connected}),
    do: row(flow, "executor", false, "No runner is connected. Cards will queue with nothing to pick them up.")

  defp executor_row(flow, %{executors: {:ok, name}}), do: row(flow, "executor", true, "Runner #{name} can run this flow.")

  defp executor_row(flow, %{executors: {:no_candidate, details}}) do
    # Per-executor, never a union: a run goes to ONE machine, so "between them they'd
    # manage it" is not readiness.
    row(flow, "executor", false, "#{count(details, "runner")} connected, but none satisfies this flow on its own.")
  end

  defp capacity_row(flow, preflight) do
    class = Atom.to_string(flow.isolation)

    if capacity_anywhere?(preflight) do
      row(flow, "capacity", true, "A connected runner advertises #{class} capacity.")
    else
      row(flow, "capacity", false, "No connected runner advertises #{class} capacity — this flow will never dispatch.")
    end
  end

  defp capacity_anywhere?(%{executors: {:ok, _name}}), do: true
  defp capacity_anywhere?(%{executors: :none_connected}), do: false
  defp capacity_anywhere?(%{executors: {:no_candidate, details}}), do: Enum.any?(details, & &1.capacity_ok?)

  defp names_row(flow, preflight, kind) do
    label = if kind == :agents, do: "agent", else: "skill"
    required = Map.fetch!(preflight.requires, kind)
    missing = missing_names(preflight, kind)

    text =
      cond do
        required == [] -> "This flow names no #{label}s."
        missing == [] -> "Every #{label} this flow names resolves on a connected runner."
        true -> "Missing #{count(missing, label)}: #{Enum.join(missing, ", ")}."
      end

    row(flow, kind, missing == [], text)
  end

  # Union across executors HERE, deliberately and only for display: with no single
  # candidate, what the developer wants is the full list of names to go install.
  defp missing_names(%{executors: {:no_candidate, details}}, kind) do
    key = if kind == :agents, do: :missing_agents, else: :missing_skills

    details |> Enum.flat_map(&Map.fetch!(&1, key)) |> Enum.uniq() |> Enum.sort()
  end

  defp missing_names(_preflight, _kind), do: []

  # Unknown ≠ missing (RLY-182): an executor that has never reported its inventory is not
  # accused of lacking anything — it gets its own caveat line instead.
  defp unreported_rows(_flow, %{unreported: []}), do: []

  defp unreported_rows(flow, %{unreported: names}) do
    [
      row(
        flow,
        "unreported",
        false,
        "#{Enum.join(names, ", ")} hasn't reported what it can run yet, so its agents and skills couldn't be checked."
      )
    ]
  end

  defp count([_one], noun), do: "1 #{noun}"
  defp count(list, noun), do: "#{length(list)} #{noun}s"

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

  # Enable body = the artboard's behavioral line (minus the version phrase, RLY-152). The
  # runner-readiness ritual that used to be inlined here is now <.preflight_list> (RLY-182),
  # which answers the same question with facts instead of a reminder.
  defp confirm_body(%Flow{enabled: false} = flow) do
    "New cards reaching #{pulls_name(flow)} will be handed to the AI automatically. " <>
      "Cards already sitting there won't move until you say so."
  end

  defp confirm_body(%Flow{} = flow) do
    "Cards reaching #{pulls_name(flow)} will stop being picked up and wait for a human " <>
      "instead. Runs already in flight finish normally. Turn the flow back on any time " <>
      "to resume automatic dispatch."
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
end
