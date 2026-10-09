defmodule RelayWeb.FlowSettingsComponents do
  @moduledoc """
  The stage row's flow pieces on Board Settings → Stages (RE431, card mockup "A — stage row owns
  its flow"). A stage holds at most one flow (RE429), so the row is the flow's home — there is no
  Flows tab any more.

    * `flow_band/1` — the violet FLOW band on a work/planning stage that holds a flow (the
      `flow_chip/1` link to the editor, `flow_meta/1`, the customized badge, the On/Off toggle
      and the ⋯ menu), the dashed no-flow band with **+ Add flow** on one that doesn't, and the
      queue note on a queue stage. Review and done stages render nothing. The reset / delete
      confirms and the RLY-182 readiness report open inside the band.
    * `copy_flow_panel/1` — the **Copy to another stage…** picker under a band: free work
      stages only, with the copy's key previewed.
    * `add_flow_panel/1` — the **+ Add flow** panel inside the no-flow band: a default-library
      flow not yet on the board, or a blank one, with its pulls-from / lands-on previewed.
    * `delete_stage_panel/1` — the inline red confirm a stage's × opens: it names the flow the
      stage takes with it (RE429 cascades it), says run history stays, and shows a
      `Relay.Boards.stage_refusal_message/1` refusal in place instead of a flash.
    * `stage_neighbours/1` — the read-only PULLS FROM → WORKS IN → LANDS ON row, worked out from
      board order (`Relay.Flows.neighbours/2`); the caller passes display names already resolved.

  Every event lives on `RelayWeb.BoardSettingsLive`. Stories live under
  `storybook/flow_settings_components/`.
  """

  use RelayWeb, :html

  alias Phoenix.HTML.Form
  alias Relay.Flows
  alias Schemas.Flow
  alias Schemas.Stage

  @doc ~S|Humanized flow name: "spec" → "Spec", "spec-copy" → "Spec copy".|
  def flow_name(%Flow{key: key}), do: key |> String.replace("-", " ") |> String.capitalize()

  @doc ~S|The ONE copy of a flow's version/size label: `"v6 · 4 nodes"` ("1 node" for one).|
  @spec flow_meta(Flow.t()) :: String.t()
  def flow_meta(%Flow{version: version} = flow), do: "v#{version} · #{nodes_label(flow)}"

  defp nodes_label(%Flow{nodes: [_single]}), do: "1 node"
  defp nodes_label(%Flow{nodes: nodes}), do: "#{length(nodes)} nodes"

  @doc """
  Whether a `Relay.Runs.preflight_flow/1` snapshot has any warning row — the readiness report
  opens after a flow is turned on only when this is true (it reports, never blocks).
  """
  @spec preflight_warns?(Flow.t(), map()) :: boolean()
  def preflight_warns?(%Flow{} = flow, preflight), do: Enum.any?(preflight_rows(flow, preflight), &(not &1.ok?))

  @doc """
  The FLOW block at the foot of a main-stage row: the violet band when the stage holds a flow,
  the dashed no-flow band (with **+ Add flow**) on a work stage without one, the queue note on a
  queue stage, and nothing on a review or done stage.
  """
  attr :stage, :map, required: true, doc: "the main stage — needs `id`, `name` and `type`"

  attr :row, :map,
    default: nil,
    doc: "nil | %{flow: %Flow{}, customized?: boolean(), resettable?: boolean()}"

  attr :neighbours, :map,
    required: true,
    doc: "%{pulls_from: String.t() | nil, lands_on: String.t() | nil} — display names, resolved"

  attr :slug, :string, required: true, doc: "the board slug, for the editor links"
  attr :panel, :atom, default: nil, doc: "this stage's open panel kind (`@panel`), or nil"
  attr :preflight, :any, default: nil, doc: "Runs.preflight_flow/1's snapshot for an open :preflight panel"
  attr :read_only?, :boolean, default: false, doc: "archived board — hides the mutating controls"

  attr :copy_targets, :list,
    default: [],
    doc: "the free work stages a copy could go on (`Flows.assignable_stages(board, nil)`); empty disables Copy"

  slot :inner_block, doc: "rendered inside the no-flow band, below its first line"

  def flow_band(%{stage: %{type: :queue}} = assigns) do
    ~H"""
    <div
      id={"stage-#{@stage.id}-queue-note"}
      class="flex flex-wrap items-center gap-2.5 rounded-[10px] bg-base-200/60 px-3.5 py-2.5"
    >
      <.flow_label />
      <span class="text-[12.5px] text-base-content/60">
        Queue — cards rest here. The next stage's flow pulls from it.
      </span>
    </div>
    """
  end

  def flow_band(%{stage: %{type: type}} = assigns) do
    cond do
      type not in Stage.work_types() -> ~H""
      is_nil(assigns.row) -> no_flow_band(assigns)
      true -> band(assigns)
    end
  end

  defp no_flow_band(assigns) do
    ~H"""
    <div
      id={"stage-#{@stage.id}-no-flow"}
      class="rounded-[10px] border border-dashed border-base-300 px-3.5 py-3"
    >
      <div class="flex flex-wrap items-center gap-2.5">
        <.flow_label />
        <span class="text-[13px] text-base-content/60">
          No flow — people work this stage by hand.
        </span>
        <span class="flex-1"></span>
        <button
          :if={!@read_only?}
          type="button"
          id={"stage-#{@stage.id}-add-flow"}
          phx-click="flow_add"
          phx-value-stage-id={@stage.id}
          class="btn btn-sm btn-outline gap-1.5"
          style="color:color-mix(in oklab, var(--color-secondary) 55%, var(--color-base-content));border-color:color-mix(in oklab, var(--color-secondary) 35%, var(--color-base-100));"
        >
          + Add flow
        </button>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp band(assigns) do
    %{flow: flow} = assigns.row

    assigns =
      assigns
      |> assign(:flow, flow)
      |> assign(:missing?, is_nil(assigns.neighbours.pulls_from) or is_nil(assigns.neighbours.lands_on))

    ~H"""
    <div
      id={"stage-#{@stage.id}-flow-band"}
      class="rounded-[10px] px-3.5 py-3 flex flex-col gap-2.5"
      style="background:color-mix(in oklab, var(--color-secondary) 4%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-secondary) 18%, var(--color-base-100));"
    >
      <div class="flex flex-wrap items-center gap-2.5">
        <.flow_label
          id={"stage-#{@stage.id}-flow-label"}
          style="color:color-mix(in oklab, var(--color-secondary) 55%, var(--color-base-content));"
        />
        <.flow_chip
          id={"stage-#{@stage.id}-ai-flow"}
          flow={@flow}
          board_slug={@slug}
          variant={:settings}
        />
        <span id={"flow-#{@flow.id}-meta"} class="font-mono text-[11px] text-base-content/55">
          {flow_meta(@flow)}
        </span>
        <span
          :if={@row.customized?}
          id={"flow-#{@flow.id}-customized"}
          class="rounded px-1.5 py-0.5 font-mono text-[9px] font-semibold tracking-[0.05em]"
          style="color:color-mix(in oklab, var(--color-primary) 60%, var(--color-base-content));background:color-mix(in oklab, var(--color-primary) 10%, var(--color-base-100));"
        >
          customized
        </span>
        <span class="flex-1"></span>
        <span id={"stage-#{@stage.id}-flow-onoff"} class="text-[12px] text-base-content/60">
          {if @flow.enabled, do: "On", else: "Off"}
        </span>
        <button
          type="button"
          id={"flow-#{@flow.id}-toggle"}
          phx-click="flow_toggle"
          phx-value-flow-id={@flow.id}
          aria-pressed={to_string(@flow.enabled)}
          aria-label={"Toggle the #{flow_name(@flow)} flow"}
          disabled={@missing? or @read_only?}
          title={
            if(@missing?,
              do: "This stage is at the end of the board — a flow needs a stage on both sides"
            )
          }
          style={toggle_style(@flow.enabled, @missing?)}
        >
          <span style={knob_style(@flow.enabled)}></span>
        </button>
        <details class="dropdown dropdown-end" id={"flow-#{@flow.id}-menu"}>
          <summary
            aria-label={"Actions for the #{flow_name(@flow)} flow"}
            class="flex size-7 cursor-pointer list-none items-center justify-center rounded-md border border-base-300 bg-base-100 text-[15px] text-base-content/70 [&::-webkit-details-marker]:hidden"
          >
            ⋯
          </summary>
          <ul class="menu dropdown-content z-10 w-60 rounded-box border border-base-300 bg-base-100 p-1 shadow-lg">
            <li>
              <.link navigate={~p"/board/#{@slug}/flows/#{@flow.key}"} id={"flow-#{@flow.id}-open"}>
                ✎ Open in flow editor
              </.link>
            </li>
            <li :if={!@read_only?} class={@copy_targets == [] && "menu-disabled"}>
              <button
                type="button"
                id={"flow-#{@flow.id}-copy"}
                phx-click="flow_copy"
                phx-value-flow-id={@flow.id}
                disabled={@copy_targets == []}
              >
                ⧉ Copy to another stage…
                <span :if={@copy_targets == []} class="text-[11px] opacity-70">
                  — every work stage already has a flow
                </span>
              </button>
            </li>
            <li :if={@row.resettable? and !@read_only?}>
              <button
                type="button"
                id={"flow-#{@flow.id}-reset"}
                phx-click="flow_reset"
                phx-value-flow-id={@flow.id}
              >
                ↺ Reset to default
              </button>
            </li>
            <li :if={!@read_only?} class={@flow.enabled && "menu-disabled"}>
              <button
                type="button"
                id={"flow-#{@flow.id}-delete"}
                phx-click="flow_delete"
                phx-value-flow-id={@flow.id}
                disabled={@flow.enabled}
              >
                🗑 Delete flow
                <span :if={@flow.enabled} class="text-[11px] opacity-70">— turn it off first</span>
              </button>
            </li>
          </ul>
        </details>
      </div>
      <.stage_neighbours
        id={"stage-#{@stage.id}-neighbours"}
        pulls_from={@neighbours.pulls_from}
        works_in={@stage.name}
        lands_on={@neighbours.lands_on}
      />
      <.reset_confirm :if={@panel == :reset} flow={@flow} />
      <.delete_confirm :if={@panel == :delete_flow} flow={@flow} />
      <div
        :if={@panel == :preflight and @preflight}
        class="flex flex-col gap-2 rounded-[10px] bg-base-100 px-4 py-3"
        style="border:1px solid color-mix(in oklab, var(--color-warning) 45%, var(--color-base-100));"
      >
        <.preflight_list flow={@flow} preflight={@preflight} />
        <div>
          <button
            type="button"
            id={"flow-#{@flow.id}-preflight-dismiss"}
            phx-click="flow_cancel_panel"
            class="btn btn-sm btn-ghost"
          >
            Got it
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The **Copy to another stage…** picker (RE431), opened from a flow's ⋯ menu and rendered under
  its band. `targets` are the free main work stages (`Relay.Flows.assignable_stages/2`), and
  `copy_key` previews the key the copy will get (`Relay.Flows.copy_key/2`). Submits
  `flow_confirm_copy` with `flow_id` and `copy[stage_id]`; changes send `flow_copy_change`.
  """
  attr :flow, Flow, required: true
  attr :form, Form, required: true, doc: "`as: :copy`, field `stage_id`"
  attr :targets, :list, required: true, doc: "[%{id: integer(), name: String.t()}]"
  attr :copy_key, :string, default: nil, doc: "the selected target's copy key, or nil"

  def copy_flow_panel(assigns) do
    ~H"""
    <div
      id={"flow-#{@flow.id}-copy-panel"}
      class="flex flex-col gap-2 rounded-[10px] border border-base-300 bg-base-100 px-4 py-3 shadow-sm"
    >
      <div class="text-[13px] font-semibold">
        Copy the <span class="font-mono">{@flow.key}</span> flow to another stage
      </div>
      <.form
        for={@form}
        id={"flow-#{@flow.id}-copy-form"}
        phx-change="flow_copy_change"
        phx-submit="flow_confirm_copy"
        class="flex flex-wrap items-center gap-2 [&_.fieldset]:mb-0"
      >
        <input type="hidden" name="flow_id" value={@flow.id} />
        <.input
          field={@form[:stage_id]}
          id={"flow-#{@flow.id}-copy-target"}
          type="select"
          aria-label="Stage to copy the flow to"
          options={Enum.map(@targets, &{&1.name, &1.id})}
          class="select select-sm w-48"
        />
        <button type="submit" id={"flow-#{@flow.id}-copy-submit"} class="btn btn-sm btn-secondary">
          Copy flow
        </button>
        <button
          type="button"
          id={"flow-#{@flow.id}-copy-cancel"}
          phx-click="flow_cancel_panel"
          class="btn btn-sm btn-ghost"
        >
          Cancel
        </button>
      </.form>
      <div class="text-[11.5px] text-base-content/60">
        Only stages without a flow are listed. The copy starts <b>off</b>
        and gets its own name (<span id={"flow-#{@flow.id}-copy-key"} class="font-mono">{@copy_key}</span>)
        — edit it from its stage.
      </div>
    </div>
    """
  end

  @doc """
  The **+ Add flow** panel (RE431), rendered inside a work stage's dashed no-flow band. Offers
  the default-library flows not yet on the board (`addable_defaults`, from
  `Relay.Flows.addable_defaults/1`) or a **Blank flow**, and previews where the new flow would
  pull from and land on. Submits `flow_confirm_add` with `stage_id` and `add[source]` /
  `add[default_key]`; changes send `flow_add_change`.
  """
  attr :stage, :map, required: true, doc: "needs `id` and `name`"
  attr :form, Form, required: true, doc: "`as: :add`, fields `source` and `default_key`"
  attr :addable_defaults, :list, required: true, doc: "library keys not yet on the board"

  attr :neighbours, :map,
    required: true,
    doc: "%{pulls_from: String.t() | nil, lands_on: String.t() | nil} — display names, resolved"

  def add_flow_panel(assigns) do
    assigns = assign(assigns, :library?, assigns.addable_defaults != [])

    ~H"""
    <div
      id={"stage-#{@stage.id}-add-flow-panel"}
      class="mt-2 rounded-lg border border-base-300 bg-base-100 p-3 shadow-sm"
    >
      <div class="mb-2 text-[12.5px] font-semibold">Add a flow to {@stage.name}</div>
      <.form
        for={@form}
        id={"stage-#{@stage.id}-add-flow-form"}
        phx-change="flow_add_change"
        phx-submit="flow_confirm_add"
      >
        <input type="hidden" name="stage_id" value={@stage.id} />
        <div class="flex flex-col gap-1.5 text-[13px]">
          <label class="flex items-center gap-2">
            <input
              type="radio"
              id={"stage-#{@stage.id}-add-source-default"}
              name={@form[:source].name}
              value="default"
              class="radio radio-xs radio-secondary"
              checked={@library? and @form[:source].value == "default"}
              disabled={!@library?}
            /> Start from the default library
            <select
              :if={@library?}
              id={"stage-#{@stage.id}-add-default-key"}
              name={@form[:default_key].name}
              aria-label="Default library flow"
              class="select select-xs ml-1 w-32"
            >
              {Phoenix.HTML.Form.options_for_select(@addable_defaults, @form[:default_key].value)}
            </select>
            <span :if={!@library?} class="text-[11.5px] text-base-content/60">
              — every library flow is already on the board
            </span>
          </label>
          <label class="flex items-center gap-2">
            <input
              type="radio"
              id={"stage-#{@stage.id}-add-source-blank"}
              name={@form[:source].name}
              value="blank"
              class="radio radio-xs radio-secondary"
              checked={!@library? or @form[:source].value == "blank"}
            /> Blank flow
          </label>
        </div>
        <div
          id={"stage-#{@stage.id}-add-flow-preview"}
          class="mt-2 text-[11.5px] text-base-content/60"
        >
          Would pull from
          <.neighbour_chip
            id={"stage-#{@stage.id}-add-flow-pulls-from"}
            name={@neighbours.pulls_from}
            kind={:pulls}
          /> and land on
          <.neighbour_chip
            id={"stage-#{@stage.id}-add-flow-lands-on"}
            name={@neighbours.lands_on}
            kind={:lands}
          />.
          It starts <b>off</b>
          — turn it on when it's ready.
        </div>
        <div class="mt-3 flex gap-2">
          <button
            type="submit"
            id={"stage-#{@stage.id}-add-flow-submit"}
            class="btn btn-sm btn-secondary"
          >
            Add flow
          </button>
          <button
            type="button"
            id={"stage-#{@stage.id}-add-flow-cancel"}
            phx-click="flow_cancel_panel"
            class="btn btn-sm btn-ghost"
          >
            Cancel
          </button>
        </div>
      </.form>
    </div>
    """
  end

  attr :id, :string, default: nil

  attr :style, :string, default: "color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"

  defp flow_label(assigns) do
    ~H"""
    <span id={@id} class="font-mono text-[11px]" style={@style}>FLOW</span>
    """
  end

  @error_ink "color:color-mix(in oklab, var(--color-error) 55%, var(--color-base-content));"

  @doc """
  The inline delete-stage confirm (card mockup A). A stage holds at most one flow and deleting the
  stage deletes it, so when `flow` is set the panel names it — key, `flow_meta/1` — and points at
  **Copy to another stage…** for keeping it. `error` is a refusal from `Boards.delete_stage/1`,
  rendered inside the panel. Confirm sends `"confirm_delete_stage"`; Cancel `"flow_cancel_panel"`.
  """
  attr :stage, :map, required: true, doc: "needs `id` and `name`"
  attr :flow, Flow, default: nil, doc: "the flow on the stage, deleted with it"
  attr :error, :string, default: nil, doc: "a refusal sentence to show in the panel"

  def delete_stage_panel(assigns) do
    assigns = assign(assigns, :ink, @error_ink)

    ~H"""
    <div
      id={"stage-#{@stage.id}-delete-panel"}
      class="flex items-start gap-3 rounded-[10px] px-4 py-3.5"
      style="background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 35%, var(--color-base-100));"
    >
      <span class="flex size-[22px] flex-none items-center justify-center rounded-full bg-error text-[13px] font-bold text-error-content">
        !
      </span>
      <div class="min-w-0 flex-1">
        <div
          id={"stage-#{@stage.id}-delete-title"}
          class="mb-1 text-[13.5px] font-semibold"
          style={@ink}
        >
          Delete the {@stage.name} stage?
        </div>
        <%= if @flow do %>
          <p
            id={"stage-#{@stage.id}-delete-flow"}
            class="mb-1.5 max-w-[560px] text-[12.5px] leading-normal"
            style={@ink}
          >
            This also deletes flow
            <code class="rounded bg-base-100 px-1 font-mono font-semibold">{@flow.key}</code>
            ({flow_meta(@flow)}) and its version history. A stage has at most one flow, so the
            flow can't outlive it.
          </p>
          <p id={"stage-#{@stage.id}-delete-history"} class="mb-3 text-[12px] text-base-content/60">
            Run history stays — past runs keep the name <span class="font-mono">{@flow.key}</span>.
            Want to keep the flow? Copy it to another stage first (⋯ → Copy to another stage).
          </p>
        <% end %>
        <p
          :if={@error}
          id={"stage-#{@stage.id}-delete-refusal"}
          role="alert"
          class="mb-3 text-[12.5px] font-semibold leading-normal"
          style={@ink}
        >
          {@error}
        </p>
        <div class={["flex flex-wrap gap-2", is_nil(@flow) && is_nil(@error) && "mt-2"]}>
          <button
            type="button"
            id={"stage-#{@stage.id}-delete-confirm"}
            phx-click="confirm_delete_stage"
            phx-value-stage-id={@stage.id}
            class="btn btn-sm btn-error"
          >
            {if @flow, do: "Delete stage and flow", else: "Delete stage"}
          </button>
          <button
            type="button"
            id={"stage-#{@stage.id}-delete-cancel"}
            phx-click="flow_cancel_panel"
            class="btn btn-sm btn-ghost"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The read-only PULLS FROM → WORKS IN → LANDS ON row for a stage's flow, labelled "worked out
  from board order". Names arrive resolved (sub-lanes as `"Plan · Done"`); a `nil` end — the
  stage is first or last on the board — renders `none` in the warning chip style.
  """
  attr :id, :string, required: true
  attr :pulls_from, :string, default: nil
  attr :works_in, :string, required: true
  attr :lands_on, :string, default: nil

  def stage_neighbours(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-1.5 gap-y-1">
      <span
        class="mr-1 font-mono text-[11px]"
        style="color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
      >
        PULLS FROM
      </span>
      <.neighbour_chip id={"#{@id}-pulls-from"} name={@pulls_from} kind={:pulls} />
      <span class="text-[12px] text-base-content/40">→</span>
      <.neighbour_chip id={"#{@id}-works-in"} name={@works_in} kind={:works} />
      <span class="text-[12px] text-base-content/40">→</span>
      <span
        class="mr-1 font-mono text-[11px]"
        style="color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
      >
        LANDS ON
      </span>
      <.neighbour_chip id={"#{@id}-lands-on"} name={@lands_on} kind={:lands} />
      <span
        id={"#{@id}-hint"}
        class="ml-1 inline-flex items-center gap-1 text-[11px] text-base-content/50"
        title="Worked out from the board order — reorder stages to change it"
      >
        <span class="font-mono">ⓘ</span> worked out from board order
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, default: nil
  attr :kind, :atom, required: true

  defp neighbour_chip(%{name: nil} = assigns) do
    ~H"""
    <span id={@id} style={chip_style(:missing)}>none</span>
    """
  end

  defp neighbour_chip(assigns) do
    ~H"""
    <span id={@id} style={chip_style(@kind)}>{@name}</span>
    """
  end

  @chip_base "font-family:var(--font-mono);font-size:11.5px;font-weight:600;padding:3px 8px;border-radius:6px;white-space:nowrap;"

  defp chip_style(:pulls),
    do:
      @chip_base <>
        "color:color-mix(in oklab, var(--color-base-content) 70%, transparent);background:var(--color-field-hover);border:1px solid var(--color-base-300);"

  defp chip_style(:works),
    do:
      @chip_base <>
        "color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));background:color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-secondary) 20%, var(--color-base-100));"

  defp chip_style(:lands),
    do:
      @chip_base <>
        "color:color-mix(in oklab, var(--color-primary) 55%, var(--color-base-content));background:color-mix(in oklab, var(--color-primary) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-primary) 25%, var(--color-base-100));"

  defp chip_style(:missing),
    do:
      @chip_base <>
        "color:color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content));background:color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 45%, var(--color-base-100));"

  attr :flow, Flow, required: true
  attr :preflight, :map, required: true

  # Reports, never blocks: the flow is already on by the time this list opens.
  defp preflight_list(assigns) do
    assigns = assign(assigns, :rows, preflight_rows(assigns.flow, assigns.preflight))

    ~H"""
    <ul
      id={"flow-#{@flow.id}-preflight"}
      style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:5px;max-width:560px;"
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
        <span style="color:color-mix(in oklab, var(--color-warning) 35%, var(--color-base-content));">
          {row.text}
        </span>
      </li>
    </ul>
    """
  end

  # Pure: preflight map → the rendered rows, in a fixed order so the banner reads the same
  # every time. Each row's id is stable and is what the LiveView tests assert on.
  defp preflight_rows(flow, preflight) do
    [
      stages_row(flow, preflight),
      runner_row(flow, preflight)
    ] ++
      capacity_rows(flow, preflight) ++
      [
        names_row(flow, preflight, :agents),
        names_row(flow, preflight, :skills)
      ] ++ unreported_rows(flow, preflight)
  end

  defp row(flow, check, ok?, text), do: %{id: "flow-#{flow.id}-preflight-#{check}", ok?: ok?, text: text}

  defp stages_row(flow, %{stages: :ok}),
    do: row(flow, "stages", true, "All three trigger stages still exist on this board.")

  # The shape problem's `what` is rendered verbatim — `Relay.Flows.Shape` owns the wording.
  defp stages_row(flow, %{stages: {:problem, problem}}), do: row(flow, "stages", false, problem.what)

  defp runner_row(flow, %{runners: :none_connected}),
    do: row(flow, "runner", false, "No runner is connected. Cards will queue with nothing to pick them up.")

  defp runner_row(flow, %{runners: {:ok, name}}), do: row(flow, "runner", true, "Runner #{name} can run this flow.")

  defp runner_row(flow, %{runners: {:no_candidate, details}}) do
    # Per-runner, never a union: a run goes to ONE machine, so "between them they'd
    # manage it" is not readiness.
    row(flow, "runner", false, "#{count(details, "runner")} connected, but none satisfies this flow on its own.")
  end

  # No runner at all is one warning (the runner row above), not two — a capacity row here
  # would only restate it for a different, misleading reason.
  defp capacity_rows(_flow, %{runners: :none_connected}), do: []
  defp capacity_rows(flow, preflight), do: [capacity_row(flow, preflight)]

  defp capacity_row(flow, preflight) do
    class = iso_label(flow.isolation)

    if capacity_anywhere?(preflight) do
      row(flow, "capacity", true, "A connected runner advertises #{class} capacity.")
    else
      row(flow, "capacity", false, "No connected runner advertises #{class} capacity — this flow will never dispatch.")
    end
  end

  defp iso_label(:shared_clean), do: "shared-clean"
  defp iso_label(:exclusive), do: "exclusive"

  defp capacity_anywhere?(%{runners: {:ok, _name}}), do: true
  defp capacity_anywhere?(%{runners: {:no_candidate, details}}), do: Enum.any?(details, & &1.capacity_ok?)

  # Nothing connected means agents/skills are unchecked, not resolved — a green "OK" here
  # would be the exact false alarm (in reverse) this feature exists to avoid.
  defp names_row(flow, %{runners: :none_connected} = preflight, kind) do
    label = if kind == :agents, do: "agent", else: "skill"
    required = Map.fetch!(preflight.requires, kind)

    if required == [] do
      row(flow, kind, true, "This flow names no #{label}s.")
    else
      row(flow, kind, false, "Can't check #{label}s — no runner is connected.")
    end
  end

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

  # Union across runners HERE, deliberately and only for display: with no single
  # candidate, what the developer wants is the full list of names to go install.
  defp missing_names(%{runners: {:no_candidate, details}}, kind) do
    key = if kind == :agents, do: :missing_agents, else: :missing_skills

    details |> Enum.flat_map(&Map.fetch!(&1, key)) |> Enum.uniq() |> Enum.sort()
  end

  defp missing_names(_preflight, _kind), do: []

  # Unknown ≠ missing (RLY-182): a runner that has never reported its inventory is not
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

  defp toggle_style(enabled?, missing?) do
    "width:38px;height:22px;border-radius:11px;position:relative;transition:background 0.18s;border:none;padding:0;" <>
      if(enabled?,
        do: "background:var(--color-primary);",
        else: "background:color-mix(in oklab, var(--color-base-content) 15%, var(--color-base-100));"
      ) <>
      if(missing?, do: "opacity:0.45;cursor:not-allowed;", else: "cursor:pointer;")
  end

  # The knob is INK on the track's fill, not a surface, so it splits on `enabled?` the way
  # `toggle_style/2` does. `base-100` here read as "white disc" from the light artboard, but it
  # is a surface token: in dark it resolves to 0.26 and punched a near-black disc into the 0.65
  # blue ON track — darker even than the 0.365 OFF track. The `-content` tokens are the ones
  # pinned light in both themes (0.98), which is what a knob needs.
  defp knob_style(enabled?) do
    knob = if enabled?, do: "var(--color-primary-content)", else: "var(--color-neutral-content)"

    "position:absolute;top:2px;" <>
      if(enabled?, do: "right:2px;", else: "left:2px;") <>
      "width:18px;height:18px;border-radius:50%;background:#{knob};transition:all 0.18s;box-shadow:0 1px 2px color-mix(in oklab, var(--color-neutral) 30%, transparent);"
  end

  attr :flow, Flow, required: true

  defp reset_confirm(assigns) do
    ~H"""
    <div
      id={"flow-#{@flow.id}-reset-confirm"}
      style="display:flex;align-items:flex-start;gap:12px;background:color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 45%, var(--color-base-100));border-radius:10px;padding:14px 16px;"
    >
      <span style="width:22px;height:22px;border-radius:50%;background:var(--color-warning);color:var(--color-warning-content);display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;flex:0 0 auto;">
        !
      </span>
      <div style="flex:1;">
        <div style="font-size:13.5px;font-weight:600;color:color-mix(in oklab, var(--color-warning) 35%, var(--color-base-content));margin-bottom:3px;">
          Reset the {flow_name(@flow)} flow to the shipped default?
        </div>
        <p style="font-size:12.5px;line-height:1.5;color:color-mix(in oklab, var(--color-warning) 40%, var(--color-base-content));margin:0 0 12px 0;max-width:560px;">
          Replace this flow's definition with the shipped default? Your customizations are
          overwritten. The flow's triggers and on/off state are untouched.
        </p>
        <div class="action-group" style="display:flex;gap:8px;">
          <.button
            type="button"
            id={"flow-#{@flow.id}-reset-cta"}
            phx-click="flow_confirm_reset"
            phx-value-flow-id={@flow.id}
            class=""
            style="background:var(--color-warning);color:var(--color-warning-content);border:none;border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
            pending="Resetting…"
          >
            Reset {flow_name(@flow)}
          </.button>
          <button
            type="button"
            id={"flow-#{@flow.id}-reset-cancel"}
            phx-click="flow_cancel_panel"
            style="background:var(--color-base-100);border:1px solid color-mix(in oklab, var(--color-warning) 40%, var(--color-base-100));color:color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content));border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :flow, Flow, required: true

  defp delete_confirm(assigns) do
    assigns = assign(assigns, :mid_run, Flows.mid_run_count(assigns.flow))

    ~H"""
    <div
      id={"flow-#{@flow.id}-delete-confirm"}
      style="display:flex;align-items:flex-start;gap:12px;background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 35%, var(--color-base-100));border-radius:10px;padding:14px 16px;"
    >
      <span style="width:22px;height:22px;border-radius:50%;background:var(--color-error);color:var(--color-error-content);display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;flex:0 0 auto;">
        !
      </span>
      <div style="flex:1;">
        <div style="font-size:13.5px;font-weight:600;color:color-mix(in oklab, var(--color-error) 55%, var(--color-base-content));margin-bottom:3px;">
          Delete the {flow_name(@flow)} flow?
        </div>
        <p style="font-size:12.5px;line-height:1.5;color:color-mix(in oklab, var(--color-error) 55%, var(--color-base-content));margin:0 0 10px 0;max-width:560px;">
          This permanently removes the flow from this board and its version history. A shipped
          default flow will not come back on the next deploy — use Reset to default instead if
          you only want to undo edits.
        </p>
        <p
          :if={@mid_run > 0}
          id={"flow-#{@flow.id}-delete-midrun"}
          style="font-size:12.5px;line-height:1.5;color:color-mix(in oklab, var(--color-error) 55%, var(--color-base-content));margin:0 0 10px 0;max-width:560px;font-weight:600;"
        >
          {@mid_run} cards are mid-run on this flow. Deleting it orphans them — their next
          hand-off fails with <span style="font-family:ui-monospace,monospace;">no_flow</span>.
        </p>
        <div class="action-group" style="display:flex;gap:8px;">
          <.button
            type="button"
            id={"flow-#{@flow.id}-delete-cta"}
            phx-click="flow_confirm_delete"
            phx-value-flow-id={@flow.id}
            class=""
            style="background:var(--color-error);color:var(--color-error-content);border:none;border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
            pending="Deleting…"
          >
            Delete {flow_name(@flow)}
          </.button>
          <button
            type="button"
            id={"flow-#{@flow.id}-delete-cancel"}
            phx-click="flow_cancel_panel"
            style="background:var(--color-base-100);border:1px solid color-mix(in oklab, var(--color-error) 30%, var(--color-base-100));color:color-mix(in oklab, var(--color-error) 60%, var(--color-base-content));border-radius:7px;padding:8px 15px;font-size:13px;font-weight:600;"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end
end
