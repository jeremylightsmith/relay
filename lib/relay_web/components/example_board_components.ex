defmodule RelayWeb.ExampleBoardComponents do
  @moduledoc """
  The read-only pieces of a public example board (RE444, card mockups "Bare minimum — Streaks
  (bare-minimum) public board + flows", "Design-led — Pantry (design-led) public board + flows"
  and "Three-brain — Tiny Dungeon (three-brain) public board + flows"): the "public example"
  banner and badges, the intro (name, pitch, baton lines, facts), the WIP explainer, one flow
  section (header, neighbour badges, its own `FlowGraphComponents.flow_graph/1` and the selected
  node's `node_panel/1`) and the card detail modal.

  Nothing here mutates. The only events are the example page's own read-only ones —
  `"select_node"` (from the graph, with `phx-value-key` + `phx-value-flow`) and `"close_card"`
  (the modal's close button and scrim). The page's other content (`<.example_intro>`'s
  `example` map, notes, blurbs) is `Relay.Examples` data.

  Stories: `storybook/example_board_components/`.
  """

  use RelayWeb, :html

  alias RelayWeb.FlowEditorComponents
  alias RelayWeb.FlowGraphComponents
  alias RelayWeb.FlowLayout
  alias Schemas.Flow.Node

  # The WIP chip and row labels mirror the stage header's at-limit chip (`wip_chip_colors(:at)`).
  @wip_ink "color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content))"
  @wip_chip_style "font-family:var(--font-mono);font-size:11px;font-weight:600;padding:1px 6px;border-radius:5px;" <>
                    "background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));color:#{@wip_ink};"

  # The mono 9.5px section label used across the flow header and the node panel.
  @pair_label "font-mono text-[9.5px] tracking-[.06em] text-base-content/40"

  @doc """
  The two header badges: `public` (success tint) and `read-only` (ghost, lock icon).
  """
  def example_badges(assigns) do
    ~H"""
    <span
      id="example-badge-public"
      class="badge badge-sm font-mono"
      style="background:color-mix(in oklab, var(--color-success) 12%, var(--color-base-100));border-color:color-mix(in oklab, var(--color-success) 35%, var(--color-base-100));color:color-mix(in oklab, var(--color-success) 65%, var(--color-base-content));"
    >
      public
    </span>
    <span id="example-badge-read-only" class="badge badge-sm badge-ghost font-mono gap-1">
      <.icon name="hero-lock-closed" class="size-3" /> read-only
    </span>
    """
  end

  @doc """
  The strip across the top of an example board: what it is, and a button to start a board from
  the same template.
  """
  attr :template_name, :string, required: true, doc: ~s(the template's display name, e.g. "Bare minimum")
  attr :slug, :string, required: true, doc: ~s(the template slug, e.g. "bare-minimum")
  attr :use_href, :string, required: true, doc: "where the Use button goes"

  def example_banner(assigns) do
    ~H"""
    <div
      id="example-banner"
      class="flex flex-wrap items-center gap-3 px-5 py-2.5 border-b border-base-300"
      style="background:color-mix(in oklab, var(--color-info) 8%, var(--color-base-100));"
    >
      <span
        id="example-banner-text"
        class="text-[12.5px]"
        style="color:color-mix(in oklab, var(--color-info) 45%, var(--color-base-content));"
      >
        <strong>This is a public example of the {@template_name} template.</strong>
        Open any card or flow to see how it works. Nothing here can be moved or edited.
      </span>
      <span class="flex-1"></span>
      <.link id="use-template" href={@use_href} class="btn btn-primary btn-sm">
        Use the {@slug} template
      </.link>
    </div>
    """
  end

  @doc """
  The board's intro: name, pitch, who holds the baton (AI and human lines) and the facts row.
  """
  attr :example, :map,
    required: true,
    doc: "a `Relay.Examples` example — reads `name`, `pitch`, `baton.ai`, `baton.human`, `facts`"

  def example_intro(assigns) do
    ~H"""
    <div id="example-intro" class="flex flex-col gap-2">
      <h1 id="example-title" class="font-semibold tracking-tight text-[22px]">{@example.name}</h1>
      <p id="example-pitch" class="text-[14px] text-base-content/55">{@example.pitch}</p>
      <div class="flex flex-wrap items-center gap-x-5 gap-y-1.5 text-[12px] text-base-content/55">
        <span id="example-baton-ai" class="flex items-center gap-1.5">
          <span
            class="inline-flex size-5 flex-none items-center justify-center rounded-full text-[9px] font-bold"
            style="background:var(--color-secondary);color:var(--color-secondary-content);"
          >
            AI
          </span>
          {@example.baton.ai}
        </span>
        <span id="example-baton-human" class="flex items-center gap-1.5">
          <span
            class="inline-flex size-5 flex-none items-center justify-center rounded-full text-[9px] font-bold"
            style="background:var(--color-primary);color:var(--color-primary-content);"
          >
            <.icon name="hero-user" class="size-3" />
          </span>
          {@example.baton.human}
        </span>
      </div>
      <p id="example-facts" class="font-mono text-[11px] text-base-content/40">{@example.facts}</p>
    </div>
    """
  end

  @doc """
  The box explaining the board's WIP limits: How they work, Why this board sets them, and what
  is happening Here.
  """
  attr :wip, :map, required: true, doc: "`%{how:, why:, here:}` from `Relay.Examples`"
  attr :chip, :string, required: true, doc: ~s(the sample chip shown in the title, e.g. "wip 2/2")

  def wip_explainer(assigns) do
    assigns =
      assign(assigns,
        chip_style: @wip_chip_style,
        rows: [
          {"wip-how", "How", assigns.wip.how},
          {"wip-why", "Why", assigns.wip.why},
          {"wip-here", "Here", assigns.wip.here}
        ],
        label_style:
          "font-family:var(--font-mono);font-size:11px;font-weight:600;min-width:42px;flex:0 0 auto;color:#{@wip_ink};"
      )

    ~H"""
    <div
      id="wip-explainer"
      class="rounded-lg border border-base-300 bg-base-100 px-3.5 py-2.5 flex flex-col gap-1.5 max-w-[980px]"
    >
      <div class="flex items-center gap-2">
        <span style={@chip_style}>{@chip}</span>
        <span class="text-[13px] font-semibold">WIP limits on this board</span>
      </div>
      <div
        :for={{id, label, text} <- @rows}
        id={id}
        class="flex gap-2 text-[12.5px] leading-[1.45] text-base-content/78"
      >
        <span style={@label_style}>{label}</span>
        <span>{text}</span>
      </div>
    </div>
    """
  end

  @doc """
  One flow, read-only: a header (key, node count, optional blurb and where it pulls from / works
  in / lands on success), the flow's own graph (`flow_graph/1` with a per-flow id and
  `phx-value-flow`) and the selected node's `node_panel/1`.
  """
  attr :flow, :map,
    required: true,
    doc: "a `Schemas.Flow` from `Relay.Flows.list_flows/1` (neighbours filled, stage preloaded)"

  attr :blurb, :string, default: nil
  attr :selected, :string, required: true, doc: "the key of the node the panel shows"
  attr :llm, :map, required: true, doc: "`%{default: name | nil, red: MapSet}` — as the flow editor passes it"
  attr :agents, :map, required: true, doc: "agent name => `%{name:, harness:}` (harness display name)"

  def example_flow(assigns) do
    %{flow: flow, selected: selected, llm: llm, agents: agents} = assigns
    node = Enum.find(flow.nodes, &(&1.key == selected))

    assigns =
      assign(assigns,
        key: flow.key,
        node: node,
        agent: node_agent(node, llm, agents),
        layout: FlowLayout.layout(flow.nodes, flow.edges),
        meta: flow_meta(length(flow.nodes), assigns.blurb),
        pairs: neighbour_pairs(flow),
        lands_on: stage_name(Map.get(flow, :lands_on_stage)),
        pair_label: @pair_label
      )

    ~H"""
    <section
      id={"example-flow-#{@key}"}
      class="bg-base-100 border border-base-300 rounded-[14px] overflow-hidden"
    >
      <header class="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-3 border-b border-base-300">
        <span class="text-[16px]">⚡</span>
        <h3 class="font-semibold text-[15px]">{@key}</h3>
        <span id={"example-flow-#{@key}-meta"} class="font-mono text-[11px] text-base-content/55">
          {@meta}
        </span>
        <span class="flex-1"></span>
        <span :for={{label, name, kind} <- @pairs} class="flex items-center gap-1.5">
          <span class={@pair_label}>{label}</span>
          <span class={pair_badge_class(kind)} style={pair_badge_style(kind)}>{name}</span>
        </span>
      </header>
      <div class="flex flex-col lg:flex-row">
        <div class="flex-1 overflow-x-auto p-3">
          <FlowGraphComponents.flow_graph
            id={"flow-graph-#{@key}"}
            flow_key={@key}
            nodes={@flow.nodes}
            edges={@flow.edges}
            layout={@layout}
            interactive?={true}
            selected={{:node, @selected}}
            lands_on={@lands_on}
            llm={@llm}
          />
        </div>
        <div class="bg-base-100 border-t lg:border-t-0 lg:border-l border-base-300 p-4 flex flex-col gap-3 lg:w-[320px] flex-none">
          <.node_panel :if={@node} flow_key={@key} node={@node} agent={@agent} />
        </div>
      </div>
    </section>
    """
  end

  @doc """
  The selected node, read-only (never the editor's `node_inspector/1`): its type tag and key,
  the model it runs on (agent nodes), and its full `run` text — tagged "inline · no skill" when
  it is an inline prompt (`Schemas.Flow.Node.inline_prompt?/1`). A control node has no `run`,
  so it shows only its tag and key.
  """
  attr :flow_key, :string, required: true
  attr :node, :map, required: true, doc: "a flow node (struct or map): `key`, `type`, `run`, `agent`"
  attr :agent, :map, default: nil, doc: "`%{name:, harness:}` the node runs on, or nil"

  def node_panel(assigns) do
    assigns =
      assign(assigns,
        run: Map.get(assigns.node, :run),
        tag: FlowGraphComponents.type_meta(assigns.node.type).tag,
        pair_label: @pair_label
      )

    ~H"""
    <aside id={"node-panel-#{@flow_key}"} data-node={@node.key} class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <span style={type_tag_style(@node.type)}>{@tag}</span>
        <span class="text-[14px] font-semibold">{@node.key}</span>
      </div>

      <div :if={@node.type == :agent and @agent} class="flex flex-col gap-1.5">
        <span class={@pair_label}>MODEL</span>
        <span
          id={"node-panel-#{@flow_key}-llm"}
          class="self-start"
          style="font-family:var(--font-mono);font-size:11px;padding:4px 9px;border-radius:6px;border:1px solid var(--color-secondary);background:color-mix(in oklab, var(--color-secondary) 10%, var(--color-base-100));"
        >
          {@agent.harness} · {@agent.name}
        </span>
      </div>

      <div :if={@run} class="flex flex-col gap-1.5">
        <div class="flex items-center gap-2">
          <span class={@pair_label}>
            {if @node.type == :gate, do: "CONDITION", else: "RUN PROMPT"}
          </span>
          <FlowEditorComponents.inline_prompt_tag
            :if={Node.inline_prompt?(@node)}
            id={"node-panel-#{@flow_key}-inline"}
          />
        </div>
        <%!-- `phx-no-format` and the flush `{@run}` are load-bearing: under `white-space:pre-wrap`
        the HEEx formatter's line break and indent inside the tag would render as a leading blank
        line and indented first line (same trap as `TalkComponents.talk_line/1`). --%>
        <div
          phx-no-format
          id={"node-panel-#{@flow_key}-prompt"}
          style="font-family:var(--font-mono);font-size:11.5px;line-height:1.55;border:1px solid var(--color-base-300);border-radius:8px;padding:10px 12px;max-height:260px;overflow:auto;white-space:pre-wrap;"
        >{@run}</div>
      </div>
    </aside>
    """
  end

  @doc """
  A sample card, read-only, in a daisyUI modal: title, ref, status, markdown description, its
  tasks and (when it is waiting on one) the open question. The close button and the scrim send
  `"close_card"`; there is nothing else to press.
  """
  attr :card, :map, required: true, doc: "`%{title:, ref:, status:, description:}` (`ref` is the formatted string)"
  attr :tasks, :list, default: [], doc: "`%{title:, done:}` per task"
  attr :question, :string, default: nil

  def example_card_detail(assigns) do
    assigns = assign(assigns, pair_label: @pair_label)

    ~H"""
    <div id="example-card-modal" class="modal modal-open" role="dialog" aria-label="Card detail">
      <div class="modal-box max-w-lg">
        <div class="flex items-center gap-2">
          <span class="font-mono text-[11px] text-base-content/55">{@card.ref}</span>
          <span id="example-card-status" class="badge badge-sm badge-ghost font-mono">
            {status_label(@card.status)}
          </span>
          <span class="flex-1"></span>
          <button
            type="button"
            id="example-card-close"
            phx-click="close_card"
            class="btn btn-sm btn-circle btn-ghost"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <h3 class="mt-2 text-lg font-semibold">{@card.title}</h3>

        <div id="example-card-description" class="prose prose-sm mt-2 max-w-none text-base-content/80">
          {Relay.Markdown.to_html(@card.description)}
        </div>

        <ul :if={@tasks != []} id="example-card-tasks" class="mt-4 flex flex-col gap-1.5 text-sm">
          <li :for={task <- @tasks} data-done={to_string(task.done)} class="flex items-center gap-2">
            <.icon
              name={if task.done, do: "hero-check-circle", else: "hero-minus-circle"}
              class={["size-4", if(task.done, do: "text-success", else: "text-base-content/40")]}
            />
            {task.title}
          </li>
        </ul>

        <div
          :if={@question}
          id="example-card-question"
          class="mt-4 rounded-lg border border-base-300 px-3 py-2 text-sm"
          style="background:color-mix(in oklab, var(--color-warning) 8%, var(--color-base-100));"
        >
          <span class={@pair_label}>QUESTION</span>
          <p class="mt-1">{@question}</p>
        </div>
      </div>
      <label class="modal-backdrop" phx-click="close_card">Close</label>
    </div>
    """
  end

  # ---- private helpers ----

  defp node_agent(%{type: :agent} = node, llm, agents), do: Map.get(agents, Map.get(node, :llm) || llm.default)
  defp node_agent(_node, _llm, _agents), do: nil

  defp flow_meta(count, blurb) do
    nodes = if count == 1, do: "1 node", else: "#{count} nodes"
    if blurb, do: "#{nodes} · #{blurb}", else: nodes
  end

  defp neighbour_pairs(flow) do
    Enum.reject(
      [
        {"PULLS FROM", stage_name(Map.get(flow, :pulls_from_stage)), :pulls},
        {"WORKS IN", stage_name(Map.get(flow, :stage)), :works},
        {"LANDS ON SUCCESS", stage_name(Map.get(flow, :lands_on_stage)), :lands}
      ],
      fn {_label, name, _kind} -> is_nil(name) end
    )
  end

  defp stage_name(%{name: name}), do: name
  defp stage_name(_none), do: nil

  defp pair_badge_class(:pulls), do: "font-mono badge badge-ghost badge-sm"
  defp pair_badge_class(_kind), do: "badge badge-sm"

  defp pair_badge_style(:pulls), do: nil
  defp pair_badge_style(:works), do: tint_style("secondary", 12)
  defp pair_badge_style(:lands), do: tint_style("primary", 10)

  defp tint_style(role, bg) do
    "background:color-mix(in oklab, var(--color-#{role}) #{bg}%, var(--color-base-100));" <>
      "border-color:color-mix(in oklab, var(--color-#{role}) 30%, var(--color-base-100));" <>
      "color:color-mix(in oklab, var(--color-#{role}) 85%, var(--color-base-content));"
  end

  # Agent nodes take the panel's violet tag; every other type the graph's own tag colours.
  defp type_tag_style(type) do
    {color, bg} =
      if type == :agent do
        {"color-mix(in oklab, var(--color-secondary) 80%, var(--color-base-content))",
         "color-mix(in oklab, var(--color-secondary) 14%, var(--color-base-100))"}
      else
        meta = FlowGraphComponents.type_meta(type)
        {meta.tag_c, meta.tag_bg || meta.fill}
      end

    "font-family:var(--font-mono);font-size:9.5px;font-weight:700;padding:1px 6px;border-radius:3px;color:#{color};background:#{bg};"
  end

  # `:needs_input` → "needs input".
  defp status_label(status), do: status |> to_string() |> String.replace("_", " ")
end
