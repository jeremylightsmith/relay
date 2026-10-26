defmodule HamacaWeb.ExampleBoardLive do
  @moduledoc """
  A template's public example board, read-only (RE444): `/examples/:template` renders the board
  seeded by `Hamaca.Examples.seed!/2` and marked with `Hamaca.Boards.mark_example/2`, for anyone —
  it lives in the router's `:public` `live_session`, so `current_scope` is nil when signed out.

  The page is the banner ("Use the <slug> template"), the intro and WIP explainer, the board's
  main stages as read-only `stage_column/1`s (no flow chips, no compose, undraggable cards), then
  one `example_flow/1` per flow in stage order, and the card detail while a card is open. The
  content beyond the board itself — pitch, notes, blurbs, the default-selected node — is
  `Hamaca.Examples` data.

  It is static: no PubSub. The only events it handles are its own read-only ones —
  `"select_card"`, `"close_card"` and `"select_node"`. Everything else the reused components can
  send (`collapse_stage`, `move_card`, `select_edge`, …) falls through the catch-all clause and
  changes nothing. An unknown slug, or a template whose example isn't seeded, is a 404.
  """
  use HamacaWeb, :live_view

  alias Hamaca.Agents
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Examples
  alias Hamaca.Flows
  alias HamacaWeb.ExampleBoardComponents
  alias Schemas.Board

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <:title>
        <span id="example-board-name" class="truncate">{@board.name}</span>
      </:title>
      <:actions>
        <ExampleBoardComponents.example_badges />
      </:actions>

      <ExampleBoardComponents.example_banner
        template_name={@template_name}
        slug={@slug}
        use_href={@use_href}
      />

      <div class="px-5 pt-5 pb-3 flex flex-col gap-2">
        <ExampleBoardComponents.example_intro example={@example} />
        <ExampleBoardComponents.wip_explainer wip={@example.wip} chip={@wip_chip} />
      </div>

      <div id="example-board" style="overflow-x:auto;padding:4px 20px 20px 20px;">
        <div style="display:flex;gap:12px;align-items:stretch;min-height:520px;">
          <%!-- `flow` and `revealed` stay at their nil defaults: no flow chips, no Done pager. --%>
          <.stage_column
            :for={column <- @columns}
            id={"stage-col-#{column.stage.position}"}
            name={column.stage.name}
            type={column.stage.type}
            category={column.stage.category}
            stage_id={column.stage.id}
            composable={false}
            read_only={true}
            collapsed={false}
            pager={false}
            main_collapsed={false}
            count={column.count}
            wip_limit={column.stage.wip_limit}
            board_key={@board.key}
            terminal={column.terminal}
            questions={@questions}
            health={%{}}
            runs={%{}}
            run_meta={%{}}
            note={Map.get(@example.notes, column.stage.name)}
            cards={column.cards}
            sublanes={column.sublanes}
          />
        </div>
      </div>

      <div id="example-flows" class="px-5 pb-10 flex flex-col gap-4">
        <div class="flex flex-wrap items-baseline gap-3 pt-2">
          <h2 class="font-semibold text-[17px]">Flows on this board</h2>
          <span class="text-[13px] text-base-content/55">
            Every prompt is written inside its flow. Copying the template copies all of them; nothing needs a
            <span class="font-mono">.claude/</span>
            folder.
          </span>
        </div>
        <ExampleBoardComponents.example_flow
          :for={flow <- @flows}
          flow={flow}
          blurb={flow_content(@example, flow.key).blurb}
          selected={Map.fetch!(@selected, flow.key)}
          llm={@llm}
          agents={@agents}
        />
      </div>

      <ExampleBoardComponents.example_card_detail
        :if={@open_card}
        card={@open_card.card}
        tasks={@open_card.tasks}
        question={@open_card.question}
      />
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"template" => slug}, _session, socket) do
    with {:ok, board} <- Boards.get_example_board(slug),
         %{} = example <- Examples.get(slug) do
      flows = board |> Flows.list_flows() |> Enum.sort_by(& &1.stage.position)
      agents = Agents.list_agents(board)
      default = Agents.default_agent(board)
      questions = Cards.needs_input_questions(board)
      columns = columns(board, Cards.list_cards(board))

      {:ok,
       socket
       |> assign(:page_title, board.name)
       |> assign(:board, board)
       |> assign(:example, example)
       |> assign(:slug, slug)
       |> assign(:template_name, template_name(slug))
       |> assign(:use_href, use_href(socket.assigns.current_scope, slug))
       |> assign(:columns, columns)
       |> assign(:wip_chip, wip_chip(columns, example.notes))
       |> assign(:questions, questions)
       |> assign(:flows, flows)
       |> assign(:selected, Map.new(flows, &{&1.key, flow_content(example, &1.key).selected}))
       |> assign(:llm, %{default: default && default.name, red: MapSet.new()})
       |> assign(:agents, Map.new(agents, &{&1.name, %{name: &1.name, harness: &1.harness.name}}))
       |> assign(:open_card, nil)}
    else
      _missing -> raise Ecto.NoResultsError, queryable: Board
    end
  end

  @impl true
  def handle_event("select_card", %{"ref" => ref}, socket) do
    %{board: board, questions: questions} = socket.assigns

    case Cards.get_card_by_ref(board, ref) do
      nil ->
        {:noreply, socket}

      card ->
        open_card = %{
          card: %{
            title: card.title,
            ref: Cards.format_ref(board.key, card.ref_number),
            status: card.status,
            description: card.description
          },
          tasks: Cards.list_tasks(card),
          question: Map.get(questions, card.id)
        }

        {:noreply, assign(socket, :open_card, open_card)}
    end
  end

  def handle_event("close_card", _params, socket), do: {:noreply, assign(socket, :open_card, nil)}

  def handle_event("select_node", %{"flow" => flow_key, "key" => node_key}, socket) do
    case Enum.find(socket.assigns.flows, &(&1.key == flow_key)) do
      %{nodes: nodes} ->
        if Enum.any?(nodes, &(&1.key == node_key)),
          do: {:noreply, update(socket, :selected, &Map.put(&1, flow_key, node_key))},
          else: {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  # Read-only: every other event the reused board components can send (collapse/expand, drag,
  # compose, edge clicks, …) is swallowed. MUST stay the last clause.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # One entry per main stage, in board order, shaped for `stage_column/1`. Every card's
  # `sub_tasks` is blanked so no face shows run-derived progress (`working · N%`, the bar).
  defp columns(board, cards) do
    cards_by_stage = cards |> Enum.map(&%{&1 | sub_tasks: []}) |> Enum.group_by(& &1.stage_id)
    {mains, subs} = Enum.split_with(board.stages, &is_nil(&1.parent_id))
    subs_by_parent = Enum.group_by(subs, & &1.parent_id)

    for stage <- mains do
      main_cards = Map.get(cards_by_stage, stage.id, [])

      sublanes =
        for sub <- subs_by_parent |> Map.get(stage.id, []) |> Enum.sort_by(&Schemas.Stage.sublane_rank(&1.type)) do
          sub_cards = Map.get(cards_by_stage, sub.id, [])

          %{
            id: sub.id,
            name: lane_label(sub.type),
            lane: sub.type,
            owner: :human,
            count: length(sub_cards),
            cards: card_tuples(sub_cards),
            collapsed: sub_cards == []
          }
        end

      %{
        stage: stage,
        count: length(main_cards),
        cards: card_tuples(main_cards),
        sublanes: sublanes,
        terminal: stage.type == :done
      }
    end
  end

  defp card_tuples(cards), do: Enum.map(cards, &{"ex-card-#{&1.id}", &1})

  # The same label BoardLive gives a sub-lane.
  defp lane_label(type), do: type |> Atom.to_string() |> String.capitalize()

  # The explainer's sample chip: the stage the example calls full, counting its sub-lanes.
  defp wip_chip(columns, notes) do
    column = Enum.find(columns, &match?(%{kind: :full}, Map.get(notes, &1.stage.name)))
    count = column.count + Enum.sum(Enum.map(column.sublanes, & &1.count))
    "wip #{count}/#{column.stage.wip_limit}"
  end

  defp flow_content(example, flow_key), do: Map.get(example.flows, flow_key, %{blurb: nil, selected: nil})

  defp template_name(slug), do: Enum.find(Boards.templates(), &(&1.slug == slug)).name

  defp use_href(nil, slug), do: ~p"/auth/google?#{[return_to: "/boards?template=#{slug}"]}"
  defp use_href(_scope, slug), do: ~p"/boards?template=#{slug}"
end
