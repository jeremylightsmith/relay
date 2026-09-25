defmodule RelayWeb.ValueStreamLive do
  @moduledoc """
  The value stream map, level 1 (RE347): a card's door-to-door stream from the board's stream
  start (`Next up`) to `Done` — the stream states coloured by who held the baton, the
  Request-changes rework the gates forced, the aligned time ladder, the to-scale lead-time bar
  and six stat tiles. Data is `Relay.ValueStream`; geometry is `RelayWeb.ValueStreamLayout`;
  rendering is the shared `RelayWeb.ValueStreamComponents` (RE349 reuses all three).

  `?card=<ref>` opens one card's actual stream (the drawer's "Value stream →"); without it — or
  on All cards — it averages `ValueStream.stream_summary/2` over the last
  `ValueStream.default_last/0` done cards or a `Relay.Runs.metric_windows/0` window. Everything
  is in the URL (`card`, `scope`, `window`) via `push_patch`, so it is linkable and the back
  button works. An unknown or other-board ref degrades to the average, like Flow Metrics.

  Realtime: subscribes to the board's `Relay.Events` topic and recomputes on the events that
  change a card's stage or a gate decision. A flow box drills into level 2
  (`RelayWeb.ValueStreamFlowLive`, RE349) with the same `card` / `scope` / `window`
  (`RelayWeb.ValueStreamParams`) and keeps a secondary "Flow metrics →" link for the same window.
  The map scrolls sideways inside an `overflow-x:auto` container at every width — there is no
  phone list (RE349).
  """
  use RelayWeb, :live_view

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Relay.Flows
  alias Relay.ValueStream
  alias RelayWeb.BoardCrumbs
  alias RelayWeb.ValueStreamComponents
  alias RelayWeb.ValueStreamLayout
  alias RelayWeb.ValueStreamParams, as: Params

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    board = Boards.get_board!(socket.assigns.current_scope.user, slug)
    if connected?(socket), do: Events.subscribe(board.id)

    {:ok,
     socket
     |> assign(:page_title, "Value stream — #{board.name}")
     |> assign(:board, board)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    card = Params.resolve_card(socket.assigns.board, Params.blank_to_nil(params["card"]))

    {:noreply,
     socket
     |> assign_card(card)
     |> assign(:scope, Params.normalize_scope(params["scope"], card))
     |> assign(:window, Params.normalize_window(params["window"]))
     |> load()}
  end

  @impl true
  def handle_event("set-window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: stream_path(socket.assigns, window: Params.normalize_window(window)))}
  end

  def handle_event("set-scope", %{"scope" => scope}, socket) do
    scope = Params.normalize_scope(scope, socket.assigns.card)
    {:noreply, push_patch(socket, to: stream_path(socket.assigns, scope: scope))}
  end

  # The events that change a card's stream: a stage change (moves — approve and reject move the
  # card too — and archives), the board's stages, and a gate decision (which lands after its move).
  @impl true
  def handle_info({:card_moved, _card, _from_stage_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:card_archived, _card}, socket), do: {:noreply, reload(socket)}
  def handle_info({:stages_changed, _board_id}, socket), do: {:noreply, reload(socket)}

  def handle_info({:timeline_appended, _card_id, %{type: type}}, socket) do
    if type in ValueStream.decision_types(), do: {:noreply, reload(socket)}, else: {:noreply, socket}
  end

  def handle_info(_event, socket), do: {:noreply, socket}

  # ── params ─────────────────────────────────────────────────────────────────

  defp assign_card(socket, nil), do: assign(socket, card: nil, card_ref: nil)
  defp assign_card(socket, card), do: assign(socket, card: card, card_ref: Cards.ref(socket.assigns.board, card))

  defp stream_path(assigns, overrides) do
    window = Keyword.get(overrides, :window, assigns.window)
    scope = Keyword.get(overrides, :scope, assigns.scope)
    Params.stream_path(assigns.board.slug, Params.query(assigns.card_ref, scope, window))
  end

  # ── data ───────────────────────────────────────────────────────────────────

  defp reload(%{assigns: %{card: nil}} = socket), do: load(socket)

  defp reload(%{assigns: %{board: board, card_ref: ref, scope: scope}} = socket) do
    card = Cards.get_card_by_ref(board, ref)

    socket
    |> assign_card(card)
    |> assign(:scope, Params.normalize_scope(to_string(scope), card))
    |> load()
  end

  defp load(socket) do
    board = socket.assigns.board
    states = ValueStream.stream_states(board.id)

    socket
    |> assign(:flows, board |> Flows.list_enabled_flows() |> Map.new(&{&1.works_in_stage_id, &1}))
    |> assign(:first, states |> List.first() |> state_name())
    |> assign(:last, states |> List.last() |> state_name())
    |> assign(:state_count, length(states))
    |> assign(:title, title(states))
    |> then(&assign_view(&1, fetch(states, &1.assigns)))
  end

  defp state_name(nil), do: nil
  defp state_name(state), do: state.name

  defp title([]), do: "The card stream"
  defp title(states), do: "The card stream — #{hd(states).name} → #{List.last(states).name}"

  defp fetch([], _assigns), do: {:empty, "This board has no Done stage."}

  defp fetch([first | _], %{scope: :card, card: card, card_ref: ref}) do
    case ValueStream.card_stream(card) do
      nil -> {:empty, "#{ref} hasn't entered the stream yet — it starts at #{first.name}."}
      stream -> {:card, stream}
    end
  end

  defp fetch(_states, %{board: board, window: window}) do
    summary = ValueStream.stream_summary(board.id, summary_opts(window))

    if summary.cards == 0,
      do: {:empty, "No card has reached Done in this window yet."},
      else: {:flow, summary}
  end

  defp summary_opts(nil), do: [last: ValueStream.default_last()]
  defp summary_opts(window), do: [window: window]

  defp assign_view(socket, {:empty, message}), do: assign(socket, empty: message, vs: nil, subject: nil)

  defp assign_view(socket, data) do
    assigns = socket.assigns
    vs = present(data, assigns.flows)
    boxes = ValueStreamLayout.boxes(vs.states)

    assign(socket,
      empty: nil,
      vs: vs,
      boxes: boxes,
      geometry: ValueStreamLayout.geometry(length(boxes)),
      ladder_items: ValueStreamLayout.ladder_items(boxes),
      rows: Map.new(vs.states, &{&1.stage_id, ValueStreamLayout.box_rows(&1, assigns.scope, vs.extras[&1.stage_id])}),
      hrefs: Map.new(vs.states, &{&1.stage_id, box_href(&1, assigns)}),
      metrics_hrefs: Map.new(vs.states, &{&1.stage_id, metrics_href(&1, assigns)}),
      tiles: tiles(vs, assigns),
      subject: subject(vs, assigns),
      callout: callout(vs, assigns)
    )
  end

  # One shape for both views, so the components never branch on where the numbers came from.
  defp present({:card, stream}, flows) do
    gates = Map.new(stream.gates, &{&1.stage_id, &1})

    extras =
      Map.new(stream.states, fn state ->
        gate = Map.get(gates, state.stage_id, %{approved: 0, rejected: 0})

        {state.stage_id,
         %{
           nodes: node_count(flows, state),
           approved: gate.approved,
           rejected: gate.rejected,
           done_at: stream.done_at
         }}
      end)

    %{
      states: stream.states,
      lead_secs: stream.lead_secs,
      baton_secs: stream.baton_secs,
      flow_efficiency: stream.flow_efficiency,
      cost: stream.cost,
      outside_secs: stream.outside_secs,
      in_progress?: is_nil(stream.done_at),
      cards: 1,
      extras: extras
    }
  end

  defp present({:flow, summary}, flows) do
    extras =
      Map.new(summary.states, &{&1.stage_id, %{nodes: node_count(flows, &1), cards_per_week: summary.cards_per_week}})

    %{
      states: summary.states,
      lead_secs: summary.mean_lead_secs,
      baton_secs: summary.baton_secs,
      flow_efficiency: summary.flow_efficiency,
      cost: summary.mean_cost,
      outside_secs: summary.outside_secs,
      in_progress?: false,
      cards: summary.cards,
      extras: extras
    }
  end

  defp node_count(flows, state) do
    case Map.get(flows, state.stage_id) do
      nil -> nil
      flow -> length(flow.nodes)
    end
  end

  # A flow box drills into level 2 (RE349) for the enabled flow that works in its stage, with the
  # same card / scope / window; its secondary link is that flow's Flow Metrics page (window, and
  # `from=<ref>` on one card).
  defp box_href(%{kind: :flow, stage_id: stage_id}, assigns) do
    case Map.get(assigns.flows, stage_id) do
      nil ->
        nil

      flow ->
        Params.flow_path(assigns.board.slug, flow.key, Params.query(assigns.card_ref, assigns.scope, assigns.window))
    end
  end

  defp box_href(_state, _assigns), do: nil

  defp metrics_href(%{kind: :flow, stage_id: stage_id}, assigns) do
    case Map.get(assigns.flows, stage_id) do
      nil -> nil
      flow -> metrics_path(assigns.board.slug, flow.key, metrics_params(assigns))
    end
  end

  defp metrics_href(_state, _assigns), do: nil

  defp metrics_params(%{window: window, scope: scope, card_ref: ref}) do
    []
    |> Params.maybe_put("window", window)
    |> Params.maybe_put("from", if(scope == :card, do: ref))
  end

  defp metrics_path(slug, key, []), do: ~p"/board/#{slug}/flows/#{key}/metrics"
  defp metrics_path(slug, key, params), do: ~p"/board/#{slug}/flows/#{key}/metrics?#{params}"

  # ── copy ───────────────────────────────────────────────────────────────────

  defp tiles(vs, assigns) do
    lead = vs.lead_secs
    batons = vs.baton_secs
    gates = Enum.count(vs.states, &(&1.kind == :gate))
    flows = Enum.count(vs.states, &(&1.kind == :flow))

    [
      tile("vs-tile-lead", lead_label(vs), fmt(lead), lead_sub(vs, assigns), :ink, false),
      tile(
        "vs-tile-efficiency",
        "FLOW EFFICIENCY",
        ValueStreamLayout.fmt_pct1(vs.flow_efficiency),
        "value-add ÷ card lead time",
        :error,
        true
      ),
      tile(
        "vs-tile-nobody",
        "BATON: NOBODY",
        share(batons.nobody, lead),
        "#{fmt(batons.nobody)} in queues",
        :warning,
        true
      ),
      tile(
        "vs-tile-human",
        "BATON: HUMAN",
        share(batons.human, lead),
        "#{fmt(batons.human)} at #{gates} #{plural(gates, "gate")}",
        :primary,
        false
      ),
      tile(
        "vs-tile-agent",
        "BATON: AGENT",
        share(batons.agent, lead),
        "#{fmt(batons.agent)} across #{flows} #{plural(flows, "flow")}",
        :secondary,
        false
      ),
      tile(
        "vs-tile-cost",
        "$ / CARD",
        ValueStreamLayout.fmt_money(vs.cost),
        "all flows, re-runs included",
        :secondary,
        false
      )
    ]
  end

  defp tile(id, label, value, sub, tone, hot), do: %{id: id, label: label, value: value, sub: sub, tone: tone, hot: hot}

  defp lead_label(%{in_progress?: true}), do: "CARD LEAD TIME · SO FAR"
  defp lead_label(_vs), do: "CARD LEAD TIME"

  defp lead_sub(%{in_progress?: true}, %{first: first}), do: "#{first} → now"

  defp lead_sub(%{cards: n}, %{scope: :flow, first: first, last: last}),
    do: "mean of #{n} done #{plural(n, "card")} · #{first} → #{last}"

  defp lead_sub(_vs, %{first: first, last: last}), do: "#{first} → #{last}"

  defp share(_secs, lead) when lead == 0, do: "—"
  defp share(secs, lead), do: ValueStreamLayout.fmt_pct(secs / lead)

  defp subject(_vs, %{scope: :card, card: card, card_ref: ref}), do: "#{ref} · #{card.title} — this card's actual stream"
  defp subject(%{cards: n}, %{window: nil}), do: "Mean of the last #{n} done #{plural(n, "card")}"
  defp subject(%{cards: n}, %{window: "all"}), do: "Mean of all #{n} done #{plural(n, "card")}"
  defp subject(%{cards: n}, %{window: window}), do: "Mean of #{n} #{plural(n, "card")} done in the last #{window}"

  # The artboard's punchline, computed: the last flow state is the one whose own metrics people
  # tune (Code on RE), and its share of the lead time is the point.
  defp callout(%{lead_secs: lead} = vs, assigns) when lead > 0 do
    case vs.states |> Enum.filter(&(&1.kind == :flow)) |> List.last() do
      nil ->
        nil

      box ->
        gates = Enum.count(vs.states, &(&1.kind == :gate))

        "A card spends #{fmt(lead)} getting from #{assigns.first} to #{assigns.last}, and " <>
          "#{ValueStreamLayout.fmt_pct1(vs.flow_efficiency)} of that is an agent actually changing the product. " <>
          "Every minute the #{box.name} flow's own metrics argue about is inside the one violet " <>
          "#{box.name} box, which accounts for #{ValueStreamLayout.fmt_pct(box.mean_secs / lead)} of the " <>
          "card's life. The queues and the #{gates} human #{plural(gates, "gate")} are the rest — and " <>
          "they are invisible from inside any flow."
    end
  end

  defp callout(_vs, _assigns), do: nil

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  defp fmt(secs), do: ValueStreamLayout.fmt_duration(secs)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide crumbs={BoardCrumbs.board(@board)}>
      <:title>
        <span id="board-name" class="truncate shrink-[1000] max-w-[58vw] sm:max-w-[280px]">
          {@board.name}
        </span>
        <.board_view_tabs board_slug={@board.slug} active={:value_stream} />
      </:title>
      <div
        id="value-stream"
        class="flex min-w-0 flex-col gap-[18px] px-4 py-5 md:px-[30px] md:py-[26px]"
      >
        <div class="flex max-w-[1120px] flex-col gap-[5px]">
          <span style="font-size:10.5px;font-weight:700;letter-spacing:0.1em;font-family:var(--font-mono);color:color-mix(in oklab, var(--color-primary) 70%, var(--color-base-content));">
            LEVEL 1 · DOOR TO DOOR
          </span>
          <h2 id="vs-title" style="font-size:20px;font-weight:600;margin:0;letter-spacing:-0.015em;">
            {@title}
          </h2>
          <p
            id="vs-explainer"
            style="font-size:13.5px;line-height:1.55;margin:0;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
          >
            {@state_count} states. Colour is the baton: <b style="color:color-mix(in oklab, var(--color-secondary) 70%, var(--color-base-content));">
              violet = an agent holds it
            </b>, <b style="color:color-mix(in oklab, var(--color-primary) 70%, var(--color-base-content));">
              blue = a human holds it
            </b>, <b style="color:color-mix(in oklab, var(--color-warning) 70%, var(--color-base-content));">
              hatched = nobody does
            </b>.
          </p>
          <p
            :if={@subject}
            id="vs-subject"
            style="font-size:12.5px;font-family:var(--font-mono);margin:0;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);"
          >
            {@subject}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <div :if={@card} id="vs-scope" class="join">
            <button
              :for={{key, label} <- Params.scope_options()}
              id={"vs-scope-#{key}"}
              type="button"
              phx-click="set-scope"
              phx-value-scope={key}
              class={["btn btn-sm join-item", to_string(@scope) == key && "btn-active"]}
            >
              {label}
            </button>
          </div>
          <div :if={@scope == :flow} id="vs-window" class="join">
            <button
              :for={{key, label} <- Params.window_options()}
              id={"vs-window-#{key}"}
              type="button"
              phx-click="set-window"
              phx-value-window={key}
              class={["btn btn-sm join-item", (@window || "last") == key && "btn-active"]}
            >
              {label}
            </button>
          </div>
        </div>

        <%= if @empty do %>
          <div
            id="vs-empty"
            class="rounded-xl border border-base-300 px-6 py-12 text-center text-sm text-base-content/70"
          >
            {@empty}
          </div>
        <% else %>
          <ValueStreamComponents.baton_legend />
          <div id="vs-map" style="overflow-x:auto;max-width:100%;">
            <div style={"position:relative;width:#{@geometry.w}px;height:#{@geometry.h}px;"}>
              <ValueStreamComponents.stream_line
                boxes={@boxes}
                geometry={@geometry}
                first={@first}
                last={@last}
              />
              <ValueStreamComponents.ladder
                items={@ladder_items}
                geometry={@geometry}
                outside={@vs.outside_secs}
              />
              <ValueStreamComponents.stream_box
                :for={box <- @boxes}
                box={box}
                rows={@rows[box.state.stage_id]}
                href={@hrefs[box.state.stage_id]}
                metrics_href={@metrics_hrefs[box.state.stage_id]}
              />
            </div>
          </div>
          <ValueStreamComponents.lead_bar
            baton={@vs.baton_secs}
            total={ValueStreamLayout.fmt_duration(@vs.lead_secs)}
          />
          <div
            id="vs-tiles"
            class="grid grid-cols-2 gap-2.5 border-t border-base-300 pt-[18px] md:flex md:flex-wrap"
          >
            <ValueStreamComponents.stat_tile
              :for={t <- @tiles}
              id={t.id}
              label={t.label}
              value={t.value}
              sub={t.sub}
              tone={t.tone}
              hot={t.hot}
            />
          </div>
          <div
            :if={@callout}
            id="vs-callout"
            style="background:color-mix(in oklab, var(--color-primary) 4%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-primary) 30%, var(--color-base-100));border-radius:12px;padding:16px 20px;max-width:1500px;"
          >
            <p style="font-size:13.5px;line-height:1.6;margin:0;color:color-mix(in oklab, var(--color-primary) 45%, var(--color-base-content));">
              <b>Read this before optimising a single node.</b> {@callout}
            </p>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
