defmodule RelayWeb.AgentsSettingsComponents do
  @moduledoc """
  Board Settings → **Agents** (RE433, card mockup "Settings → Agents: named agents pick a model
  from their harness's list; each harness configures how its usage is read"). A board's named
  agents (a harness plus one of its models, one of them the default) and the harnesses they run
  on.

    * `agents_pane/1` — the whole pane: page head, the agents table, the open agent panel, the
      harness cards and the **+ Add harness** footer. It only composes the pieces below.
    * `agents_table/1` — NAME / HARNESS / MODEL / USED BY rows with the DEFAULT badge, **Make
      default** and **Edit**. A red agent (`Relay.Agents.red?/1`, its model left its harness's
      list) gets the error inset, a MODEL REMOVED badge and a struck-through model.
    * `agent_form/1` — the Add / Edit agent panel. MODEL is a select over the harness's models
      only (never free text); a red agent's edit opens on `Choose a model…` and keeps Save
      disabled until one is picked.
    * `harness_card/1` — a harness's COMMAND and MODELS, with the red line naming any agent whose
      model left the list.
    * `harness_form/1` — the Edit / Add harness card, with RESUME COMMAND, SESSION ID PATH and
      SIGNED-IN CHECK tucked in a closed **Advanced** `<details>` (a deliberate departure from the
      mockup, which has no slot for them).

  Every event lives on `RelayWeb.BoardSettingsLive`. Stories live under
  `storybook/agents_settings_components/`.
  """

  use RelayWeb, :html

  alias Relay.Agents
  alias Schemas.Agent
  alias Schemas.Harness

  @grid "grid-template-columns:1.3fr 1fr 1.1fr 90px 120px;"
  @panel_style "border:1px solid color-mix(in oklab, var(--color-primary) 35%, var(--color-base-100));background:color-mix(in oklab, var(--color-primary) 3%, var(--color-base-100));padding:16px 18px;"
  @chip_style "font-size:10.5px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);background:var(--color-field-hover, var(--color-base-200));border-radius:4px;padding:2px 6px;font-family:ui-monospace,monospace;"
  @badge_style "font-size:9.5px;letter-spacing:.06em;font-weight:700;"
  @red_ink "color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));"
  @red_row "box-shadow:inset 3px 0 0 var(--color-error);background:color-mix(in oklab, var(--color-error) 8%, var(--color-base-100));"
  @delete_ink "color:color-mix(in oklab, var(--color-error) 65%, var(--color-base-content));"

  # ------------------------------------------------------------------ pane

  @doc """
  The Agents pane body. `agent_panel` is `nil`, `{:new, harness}` (the picked harness) or
  `{:edit, agent}`; `harness_panel` is `nil`, `:new` or `{:edit, harness}`.
  """
  attr :harnesses, :list, required: true
  attr :agents, :list, required: true, doc: "the board's agents, `:harness` preloaded"
  attr :default_agent_id, :any, required: true
  attr :usage, :map, required: true, doc: "`Relay.Agents.node_usage/1`"
  attr :agent_panel, :any, default: nil
  attr :agent_form, :any, default: nil
  attr :agents_error, :string, default: nil
  attr :harness_panel, :any, default: nil
  attr :harness_form, :any, default: nil
  attr :harness_error, :string, default: nil
  attr :read_only?, :boolean, default: false

  def agents_pane(assigns) do
    ~H"""
    <.page_heading class="mb-1.5">Agents</.page_heading>
    <p
      class="text-base-content/65"
      style="font-size:14px;line-height:1.55;margin:0 0 22px;max-width:600px;"
    >
      The LLMs this board's flows may run. Each is a harness plus a model; flow nodes pick one by name,
      or inherit the <b>default</b>. API keys never live here — runners use their own environment.
    </p>

    <.agents_table
      agents={@agents}
      default_agent_id={@default_agent_id}
      usage={@usage}
      read_only?={@read_only?}
    />

    <.agent_form
      :if={@agent_panel}
      form={@agent_form}
      panel={@agent_panel}
      harnesses={@harnesses}
      error={@agents_error}
    />

    <div :if={!@read_only? and is_nil(@agent_panel)} class="mt-3">
      <button type="button" id="agent-add" class="btn btn-sm btn-outline" phx-click="agent_new">
        + Add agent
      </button>
    </div>

    <section id="harnesses">
      <h2 style="font-size:16px;font-weight:600;margin:36px 0 4px;">Harnesses</h2>
      <p
        class="text-base-content/65"
        style="font-size:13px;line-height:1.55;margin:0 0 14px;max-width:620px;"
      >
        The CLIs an agent can run on. Each one is a name, a command, and the models its agents can
        choose from. Every board starts with Claude Code, Codex and Gemini CLI filled in. Edit them
        like any other harness, or add pi, opencode, aider or an internal tool. Every runner sees the
        same command, and a runner without it installed won't claim its nodes.
      </p>
      <div class="flex flex-col gap-3">
        <%= for harness <- @harnesses do %>
          <%= if editing_harness?(@harness_panel, harness) do %>
            <.harness_form
              form={@harness_form}
              harness={harness}
              agent_count={Enum.count(@agents, &(&1.harness_id == harness.id))}
              error={@harness_error}
            />
          <% else %>
            <.harness_card
              harness={harness}
              agents={Enum.filter(@agents, &(&1.harness_id == harness.id))}
              read_only?={@read_only?}
            />
          <% end %>
        <% end %>
        <.harness_form
          :if={@harness_panel == :new}
          form={@harness_form}
          harness={nil}
          agent_count={0}
          error={@harness_error}
        />
      </div>
      <div class="flex items-center gap-3 mt-3 flex-wrap">
        <button
          :if={!@read_only?}
          type="button"
          id="harness-add"
          class="btn btn-sm btn-outline"
          phx-click="harness_new"
        >
          + Add harness
        </button>
        <span class="text-base-content/65" style="font-size:11.5px;">
          You can remove a harness once no agent uses it.
        </span>
      </div>
    </section>
    """
  end

  defp editing_harness?({:edit, %Harness{id: id}}, %Harness{id: id}), do: true
  defp editing_harness?(_panel, _harness), do: false

  # ------------------------------------------------------------------ agents table

  @doc """
  The agents table. USED BY reads `all others` on the default row and counts the nodes naming an
  agent explicitly (`Relay.Agents.node_usage/1`) on the rest.
  """
  attr :agents, :list, required: true, doc: "the board's agents, `:harness` preloaded"
  attr :default_agent_id, :any, required: true
  attr :usage, :map, required: true, doc: "agent name → `[{flow_key, node_key}]`"
  attr :read_only?, :boolean, default: false

  def agents_table(assigns) do
    assigns = assign(assigns, grid: @grid, badge_style: @badge_style, red_ink: @red_ink)

    ~H"""
    <div id="agents-table" class="border border-base-300 rounded-xl overflow-hidden bg-base-100">
      <div
        class="hidden sm:grid bg-base-200 border-b border-base-300"
        style={@grid <> "padding:9px 16px;gap:12px;"}
      >
        <.meta_label>NAME</.meta_label>
        <.meta_label>HARNESS</.meta_label>
        <.meta_label>MODEL</.meta_label>
        <.meta_label>USED BY</.meta_label>
        <span></span>
      </div>
      <div
        :for={agent <- @agents}
        id={"agent-row-#{agent.id}"}
        data-agent={agent.name}
        data-red={if Agents.red?(agent), do: "true"}
        class="grid items-center border-b border-base-300 last:border-b-0"
        style={row_style(@grid, Agents.red?(agent))}
      >
        <div class="flex items-center gap-2 min-w-0 flex-wrap">
          <span style="font-weight:600;font-size:14px;">{agent.name}</span>
          <span
            :if={agent.id == @default_agent_id}
            id={"agent-row-#{agent.id}-default"}
            class="badge badge-sm badge-secondary badge-soft font-mono"
            style={@badge_style}
          >
            DEFAULT
          </span>
          <span
            :if={Agents.red?(agent)}
            id={"agent-row-#{agent.id}-removed"}
            class="badge badge-sm badge-error badge-soft font-mono"
            style={@badge_style}
          >
            MODEL REMOVED
          </span>
        </div>
        <span style="font-size:13px;">{agent.harness.name}</span>
        <%= if Agents.red?(agent) do %>
          <span class="flex flex-col min-w-0">
            <span class="font-mono line-through" style="font-size:12.5px;color:var(--color-error);">
              {agent.model}
            </span>
            <span style={"font-size:11px;" <> @red_ink}>not in {agent.harness.name}'s models</span>
          </span>
        <% else %>
          <span class="font-mono" style="font-size:12.5px;">{agent.model}</span>
        <% end %>
        <span data-used-by class="font-mono text-base-content/65" style="font-size:12px;">
          {used_by(agent, @default_agent_id, @usage)}
        </span>
        <span :if={!@read_only?} class="flex justify-end gap-1">
          <button
            :if={agent.id != @default_agent_id}
            type="button"
            id={"agent-row-#{agent.id}-make-default"}
            class="btn btn-ghost btn-xs"
            phx-click="agent_make_default"
            phx-value-id={agent.id}
          >
            Make default
          </button>
          <button
            type="button"
            id={"agent-row-#{agent.id}-edit"}
            class="btn btn-ghost btn-xs"
            phx-click="agent_edit"
            phx-value-id={agent.id}
          >
            Edit
          </button>
        </span>
      </div>
    </div>
    """
  end

  defp row_style(grid, true), do: grid <> "padding:12px 16px;gap:12px;" <> @red_row
  defp row_style(grid, false), do: grid <> "padding:12px 16px;gap:12px;"

  defp used_by(%Agent{id: id}, id, _usage), do: "all others"

  defp used_by(%Agent{name: name}, _default_id, usage) do
    case length(Map.get(usage, name, [])) do
      0 -> "—"
      1 -> "1 node"
      n -> "#{n} nodes"
    end
  end

  # ------------------------------------------------------------------ agent form

  @doc """
  The Add / Edit agent panel. `panel` is `{:new, harness}` — HARNESS buttons, the picked one
  primary — or `{:edit, agent}`, where the harness is fixed. A red agent's edit opens on a blank
  `Choose a model…` and keeps Save disabled until a current model is picked.
  """
  attr :form, :any, required: true, doc: "a `to_form/1` of `Relay.Agents.change_agent/2`"
  attr :panel, :any, required: true, doc: "`{:new, harness}` or `{:edit, agent}`"
  attr :harnesses, :list, default: []
  attr :error, :string, default: nil

  def agent_form(assigns) do
    {harness, red?} =
      case assigns.panel do
        {:new, harness} -> {harness, false}
        {:edit, agent} -> {agent.harness, Agents.red?(agent)}
      end

    model = assigns.form[:model].value
    chosen? = model in harness.models

    assigns =
      assign(assigns,
        harness: harness,
        red?: red?,
        model: if(chosen?, do: model),
        save_disabled?: red? and not chosen?,
        panel_style: @panel_style,
        delete_ink: @delete_ink,
        red_ink: @red_ink
      )

    ~H"""
    <div class="mt-4 rounded-xl" style={@panel_style}>
      <.form for={@form} id="agent-form" phx-change="agent_validate" phx-submit="agent_save">
        <div class="flex items-center gap-2 mb-3">
          <span style="font-weight:600;font-size:14px;">
            <%= case @panel do %>
              <% {:new, _harness} -> %>
                Add agent
              <% {:edit, agent} -> %>
                Edit agent · {agent.name}
            <% end %>
          </span>
          <span class="flex-1"></span>
          <button type="button" class="btn btn-ghost btn-xs" phx-click="agent_cancel">Cancel</button>
        </div>
        <div class="flex flex-col gap-4">
          <div :if={match?({:new, _}, @panel)} class="flex flex-col gap-2">
            <.meta_label>HARNESS</.meta_label>
            <input type="hidden" name={@form[:harness_id].name} value={@harness.id} />
            <div class="join flex-wrap">
              <button
                :for={h <- @harnesses}
                type="button"
                id={"agent-form-harness-#{h.id}"}
                class={["btn btn-sm join-item", h.id == @harness.id && "btn-primary"]}
                phx-click="agent_pick_harness"
                phx-value-id={h.id}
              >
                {h.name}
              </button>
            </div>
          </div>
          <div class="grid gap-4 sm:grid-cols-2">
            <div class="flex flex-col gap-2">
              <.meta_label>MODEL</.meta_label>
              <.input
                field={@form[:model]}
                type="select"
                id="agent-form-model"
                class="select select-sm w-full font-mono"
                options={@harness.models}
                value={@model}
                prompt={if @red?, do: "Choose a model…"}
              />
              <span class="text-base-content/65" style="font-size:11.5px;">
                <%= if @red? do %>
                  Only {@harness.name}'s current models.
                  <span class="font-mono">{elem(@panel, 1).model}</span>
                  isn't offered any more, so this row stays red until you pick one.
                <% else %>
                  {@harness.name}'s models. To offer another, add it to {@harness.name} under Harnesses.
                <% end %>
              </span>
            </div>
            <div class="flex flex-col gap-2">
              <.meta_label>NAME</.meta_label>
              <.input field={@form[:name]} id="agent-form-name" class="input input-sm w-full" />
              <span class="text-base-content/65" style="font-size:11.5px;">
                What flow nodes show. Must be unique on this board.
              </span>
            </div>
          </div>
          <p
            :if={@error}
            id="agent-error"
            class="rounded-lg"
            style={"font-size:12px;padding:7px 10px;" <> @red_ink}
          >
            {@error}
          </p>
          <div class="flex items-center gap-2">
            <button
              type="submit"
              id="agent-form-save"
              class="btn btn-sm btn-primary"
              disabled={@save_disabled?}
            >
              {if match?({:new, _}, @panel), do: "Add agent", else: "Save"}
            </button>
            <span class="flex-1"></span>
            <button
              :if={match?({:edit, _}, @panel)}
              type="button"
              id="agent-delete"
              class="btn btn-ghost btn-xs"
              style={@delete_ink}
              phx-click="agent_delete"
            >
              Delete agent
            </button>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  # ------------------------------------------------------------------ harness card

  @doc """
  A harness card: name, `used by N agent(s)`, COMMAND and MODELS chips, and the red line when an
  agent on it uses a model the list no longer offers.
  """
  attr :harness, Harness, required: true
  attr :agents, :list, default: [], doc: "the agents on this harness, `:harness` preloaded"
  attr :read_only?, :boolean, default: false

  def harness_card(assigns) do
    assigns =
      assign(assigns,
        red: Enum.filter(assigns.agents, &Agents.red?/1),
        chip_style: @chip_style,
        red_ink: @red_ink
      )

    ~H"""
    <div
      id={"harness-card-#{@harness.id}"}
      class="border border-base-300 rounded-xl bg-base-100"
      style="padding:14px 16px;"
    >
      <div class="flex items-center gap-2 flex-wrap">
        <span style="font-weight:600;font-size:14px;">{@harness.name}</span>
        <span class="font-mono text-base-content/65" style="font-size:11.5px;">
          {used_by_agents(length(@agents))}
        </span>
        <span class="flex-1"></span>
        <button
          :if={!@read_only?}
          type="button"
          id={"harness-card-#{@harness.id}-edit"}
          class="btn btn-ghost btn-xs"
          phx-click="harness_edit"
          phx-value-id={@harness.id}
        >
          Edit
        </button>
      </div>
      <div class="grid gap-3 md:grid-cols-[1fr_260px] mt-3">
        <div class="flex flex-col gap-2 min-w-0">
          <.meta_label>COMMAND</.meta_label>
          <%!-- The command is interpolated as a value (its `{…}` placeholders are data, not HEEx);
               phx-no-format keeps white-space:pre free of template indentation. --%>
          <code
            class="block font-mono rounded-lg bg-base-200 border border-base-300"
            style="font-size:12.5px;padding:9px 11px;overflow-x:auto;white-space:pre;"
            phx-no-format
          >{@harness.command}</code>
        </div>
        <div class="flex flex-col gap-2 min-w-0">
          <.meta_label>MODELS</.meta_label>
          <div class="flex gap-1 flex-wrap">
            <span :for={model <- @harness.models} data-model-chip style={@chip_style}>{model}</span>
          </div>
        </div>
      </div>
      <div
        :if={@red != []}
        id={"harness-card-#{@harness.id}-red"}
        class="flex items-center gap-2 mt-3 rounded-lg"
        style={"font-size:12px;padding:7px 10px;" <> @red_ink <> "background:color-mix(in oklab, var(--color-error) 8%, var(--color-base-100));"}
      >
        <span>
          {red_count(length(@red))} a model that isn't on this list: <span :for={
            {agent, i} <- Enum.with_index(@red)
          }>{if i > 0, do: ", "}<b>{agent.name}</b> (<span class="font-mono">{agent.model}</span>)</span>.
        </span>
      </div>
    </div>
    """
  end

  defp used_by_agents(1), do: "used by 1 agent"
  defp used_by_agents(n), do: "used by #{n} agents"

  defp red_count(1), do: "1 agent uses"
  defp red_count(n), do: "#{n} agents use"

  # ------------------------------------------------------------------ harness form

  @doc """
  The Edit / Add harness card. `harness` is the harness being edited, or nil for **+ Add
  harness**. The COMMAND hint lists every `Schemas.Harness.placeholders/0` entry; RESUME COMMAND,
  SESSION ID PATH and SIGNED-IN CHECK sit in a closed **Advanced** `<details>`.
  """
  attr :form, :any, required: true, doc: "a `to_form/1` of `Relay.Agents.change_harness/2`"
  attr :harness, :any, default: nil, doc: "the harness being edited, nil when adding"
  attr :agent_count, :integer, default: 0
  attr :error, :string, default: nil

  def harness_form(assigns) do
    assigns =
      assign(assigns,
        placeholders: Harness.placeholders(),
        models_value: models_value(assigns.form[:models].value),
        panel_style: @panel_style,
        chip_style: @chip_style,
        delete_ink: @delete_ink,
        red_ink: @red_ink
      )

    ~H"""
    <div
      id={if @harness, do: "harness-card-#{@harness.id}", else: "harness-card-new"}
      class="rounded-xl"
      style={@panel_style}
    >
      <.form for={@form} id="harness-form" phx-change="harness_validate" phx-submit="harness_save">
        <div class="flex items-start gap-2 flex-wrap">
          <div style="width:180px;">
            <.input
              field={@form[:name]}
              id="harness-form-name"
              placeholder="Name"
              class="input input-sm font-semibold"
            />
          </div>
          <span :if={@harness} class="font-mono text-base-content/65 mt-1.5" style="font-size:11.5px;">
            {used_by_agents(@agent_count)}
          </span>
          <span class="flex-1"></span>
          <button type="button" class="btn btn-ghost btn-xs" phx-click="harness_cancel">
            Cancel
          </button>
          <button type="submit" id="harness-form-save" class="btn btn-primary btn-xs">Save</button>
        </div>
        <div class="grid gap-3 md:grid-cols-[1fr_260px] mt-3">
          <div class="flex flex-col gap-2 min-w-0">
            <.meta_label>COMMAND</.meta_label>
            <.input
              field={@form[:command]}
              id="harness-form-command"
              class="input input-sm w-full font-mono text-[12.5px]"
            />
            <span class="text-base-content/65" style="font-size:11.5px;">
              Placeholders:
              <span :for={p <- @placeholders} data-placeholder-chip style={@chip_style}>
                {"{" <> p <> "}"}
              </span>
            </span>
          </div>
          <div class="flex flex-col gap-2 min-w-0">
            <.meta_label>MODELS</.meta_label>
            <.input
              field={@form[:models]}
              id="harness-form-models"
              value={@models_value}
              class="input input-sm w-full font-mono text-[12.5px]"
            />
            <span class="text-base-content/65" style="font-size:11.5px;">
              Comma-separated. These are the only models agents on {harness_label(@harness, @form)} can pick.
            </span>
          </div>
        </div>
        <details id="harness-form-advanced" class="mt-3">
          <summary class="cursor-pointer text-base-content/65" style="font-size:12px;">
            Advanced
          </summary>
          <div class="grid gap-3 md:grid-cols-2 mt-3">
            <div class="flex flex-col gap-2 min-w-0 md:col-span-2">
              <.meta_label>RESUME COMMAND</.meta_label>
              <.input
                field={@form[:resume_command]}
                id="harness-form-resume-command"
                class="input input-sm w-full font-mono text-[12.5px]"
              />
            </div>
            <div class="flex flex-col gap-2 min-w-0">
              <.meta_label>SESSION ID PATH</.meta_label>
              <.input
                field={@form[:session_id_path]}
                id="harness-form-session-id-path"
                class="input input-sm w-full font-mono text-[12.5px]"
              />
            </div>
            <div class="flex flex-col gap-2 min-w-0">
              <.meta_label>SIGNED-IN CHECK</.meta_label>
              <.input
                field={@form[:signed_in_check]}
                id="harness-form-signed-in-check"
                class="input input-sm w-full font-mono text-[12.5px]"
              />
            </div>
          </div>
        </details>
        <p
          :if={@error}
          id="harness-error"
          class="mt-3 rounded-lg"
          style={"font-size:12px;padding:7px 10px;" <> @red_ink}
        >
          {@error}
        </p>
        <div :if={@harness} class="flex mt-3">
          <button
            type="button"
            id="harness-delete"
            class="btn btn-ghost btn-xs"
            style={@delete_ink}
            phx-click="harness_delete"
          >
            Remove harness
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp models_value(models) when is_list(models), do: Enum.join(models, ", ")
  defp models_value(models), do: models

  defp harness_label(%Harness{name: name}, _form), do: name

  defp harness_label(nil, form) do
    case form[:name].value do
      name when is_binary(name) and name != "" -> name
      _blank -> "this harness"
    end
  end
end
