defmodule RelayWeb.ValueStreamFlowLive do
  @moduledoc """
  The value stream map, level 2 (RE349): the drill-down behind a level-1 flow box — every node of
  one flow on one line in execution order, coloured by role (`Schemas.Flow.node_roles/1`: Do /
  Check / Fix), fix nodes lifted above the line, the send-back and re-entry arcs sized by real
  minutes, the aligned time ladder, the two-band run lead-time bar and six stat tiles
  (`docs/designs/Value Stream Map v2.dc.html`, level 2).

  Data is `Relay.ValueStream.flow_stream/2`; geometry and per-run figures are
  `RelayWeb.ValueStreamFlowLayout` (derived from the flow graph, so any flow drills — nothing is
  specific to `code.json`); rendering is `RelayWeb.ValueStreamComponents`. URL state (`card`,
  `scope`, `window`) is level 1's, through `RelayWeb.ValueStreamParams`. Last N (no `window`)
  scopes the roll-up to the same done cards level 1 averages (`ValueStream.done_card_ids/2` →
  `card_ids:`); This card uses `card_id:`; a window uses `window:`. An unknown flow key
  redirects to level 1 with a flash.

  Realtime: subscribes to `Relay.Runs.subscribe/1` and recomputes on `{:run_changed, card_id}`.
  """
  use RelayWeb, :live_view

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Runs
  alias Relay.ValueStream
  alias RelayWeb.BoardCrumbs
  alias RelayWeb.FlowSettingsComponents
  alias RelayWeb.ValueStreamComponents
  alias RelayWeb.ValueStreamFlowLayout, as: FlowLayout
  alias RelayWeb.ValueStreamLayout
  alias RelayWeb.ValueStreamParams, as: Params

  @impl true
  def mount(%{"slug" => slug, "flow_key" => key}, _session, socket) do
    board = Boards.get_board!(socket.assigns.current_scope.user, slug)

    case Flows.get_flow_with_stages(board, key) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "There is no \"#{key}\" flow on this board.")
         |> push_navigate(to: Params.stream_path(slug, []))}

      flow ->
        if connected?(socket), do: Runs.subscribe(board.id)
        name = FlowSettingsComponents.flow_name(flow)

        {:ok,
         socket
         |> assign(:page_title, "#{name} flow — value stream — #{board.name}")
         |> assign(board: board, flow: flow, name: name, flow_layout: FlowLayout.layout(flow))}
    end
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
    {:noreply, push_patch(socket, to: flow_path(socket.assigns, window: Params.normalize_window(window)))}
  end

  def handle_event("set-scope", %{"scope" => scope}, socket) do
    scope = Params.normalize_scope(scope, socket.assigns.card)
    {:noreply, push_patch(socket, to: flow_path(socket.assigns, scope: scope))}
  end

  # `{:run_changed, card_id}` is the runs topic's coarse public contract (RLY-137) — refetch.
  @impl true
  def handle_info({:run_changed, _card_id}, socket), do: {:noreply, reload(socket)}
  def handle_info(_event, socket), do: {:noreply, socket}

  # ── params ─────────────────────────────────────────────────────────────────

  defp assign_card(socket, nil), do: assign(socket, card: nil, card_ref: nil)

  defp assign_card(socket, card), do: assign(socket, card: card, card_ref: Relay.Cards.ref(socket.assigns.board, card))

  defp flow_path(assigns, overrides) do
    window = Keyword.get(overrides, :window, assigns.window)
    scope = Keyword.get(overrides, :scope, assigns.scope)
    Params.flow_path(assigns.board.slug, assigns.flow.key, Params.query(assigns.card_ref, scope, window))
  end

  defp back_path(assigns),
    do: Params.stream_path(assigns.board.slug, Params.query(assigns.card_ref, assigns.scope, assigns.window))

  # ── data ───────────────────────────────────────────────────────────────────

  defp reload(%{assigns: %{card: nil}} = socket), do: load(socket)

  defp reload(%{assigns: %{board: board, card_ref: ref, scope: scope}} = socket) do
    card = Params.resolve_card(board, ref)

    socket
    |> assign_card(card)
    |> assign(:scope, Params.normalize_scope(to_string(scope), card))
    |> load()
  end

  defp load(socket) do
    assigns = socket.assigns
    {opts, last_n} = population(assigns)
    stream = ValueStream.flow_stream(assigns.flow, opts)

    if stream.runs == 0 do
      assign(socket, empty: empty_message(assigns), view: nil, subject: nil)
    else
      assign(socket, empty: nil, subject: subject(assigns, stream, last_n), view: present(assigns, stream))
    end
  end

  # {flow_stream opts, the Last-N card count (nil unless Last N)}
  defp population(%{scope: :card, card: card}), do: {[card_id: card.id], nil}

  defp population(%{board: board, window: nil}) do
    ids = ValueStream.done_card_ids(board.id, last: ValueStream.default_last())
    {[card_ids: ids], length(ids)}
  end

  defp population(%{window: window}), do: {[window: window], nil}

  defp present(%{flow_layout: layout, flow: flow} = assigns, stream) do
    summary = FlowLayout.summary(layout, stream)

    %{
      stream: stream,
      boxes: FlowLayout.node_boxes(layout, stream),
      arcs: FlowLayout.arcs(layout, stream.sends),
      ladder_items: FlowLayout.ladder_items(layout, stream),
      queue: FlowLayout.queue(flow.isolation, stream.queue_wait),
      terminals: FlowLayout.terminals(layout, stream, landing(flow)),
      bands: FlowLayout.bands(summary),
      tiles: tiles(summary, card_lead(assigns))
    }
  end

  defp landing(%{lands_on_stage: %Schemas.Stage{} = stage}), do: Boards.stage_display_name(stage)
  defp landing(_flow), do: nil

  # The card's lead time (This card) or the mean lead of the same card population (All cards),
  # for RUN WALL-CLOCK's "% of the card"; nil when unavailable.
  defp card_lead(%{scope: :card, card: card}) do
    case ValueStream.card_stream(card) do
      nil -> nil
      stream -> stream.lead_secs
    end
  end

  defp card_lead(%{board: board, window: window}) do
    summary = ValueStream.stream_summary(board.id, summary_opts(window))
    if summary.cards > 0, do: summary.mean_lead_secs
  end

  defp summary_opts(nil), do: [last: ValueStream.default_last()]
  defp summary_opts(window), do: [window: window]

  # ── copy ───────────────────────────────────────────────────────────────────

  defp tiles(s, card_lead) do
    [
      tile("vs-tile-run-wall", "RUN WALL-CLOCK", fmt(s.wall), "#{share(s.wall, card_lead)} of the card", :ink, false),
      tile(
        "vs-tile-flow-efficiency",
        "FLOW EFFICIENCY",
        share(s.value_add, s.wall),
        "value-add ÷ run wall-clock",
        :success,
        true
      ),
      tile("vs-tile-rework", "REWORK", share(s.rework, s.wall), "#{fmt(s.rework)} on the line", :error, true),
      tile("vs-tile-rewind", "REWIND COST", fmt(s.rewind_cost), rewind_sub(s.rewind_fixes), :error, true),
      tile(
        "vs-tile-first-pass",
        "ROLLED 1ST-PASS",
        "#{ValueStreamLayout.fmt_pct(s.first_pass_run)} / #{ValueStreamLayout.fmt_pct(s.first_pass_task)}",
        "per run / per task",
        :error,
        false
      ),
      tile(
        "vs-tile-spend",
        "SPEND / RUN",
        ValueStreamLayout.fmt_money(s.spend),
        "#{ValueStreamLayout.fmt_money(s.rework_spend)} of it rework",
        :secondary,
        false
      )
    ]
  end

  defp tile(id, label, value, sub, tone, hot), do: %{id: id, label: label, value: value, sub: sub, tone: tone, hot: hot}

  defp rewind_sub([]), do: "no fix rewinds past a passed check"
  defp rewind_sub(fixes), do: "#{Enum.join(fixes, " + ")} + the re-checks it forces"

  defp share(_part, whole) when whole in [nil, 0, +0.0], do: "—"
  defp share(part, whole), do: ValueStreamLayout.fmt_pct(part / whole)

  defp fmt(secs), do: FlowLayout.fmt_minutes(secs)

  defp empty_message(%{scope: :card, card_ref: ref, name: name}), do: "#{ref} has no #{name} runs yet."
  defp empty_message(%{name: name}), do: "No runs of #{name} in this window yet."

  defp subject(%{scope: :card, card_ref: ref, card: card, name: name}, stream, _n),
    do: "#{ref} · #{card.title} — this card's #{runs(stream.runs, name)}"

  defp subject(%{window: nil, name: name}, stream, n),
    do: "The #{runs(stream.runs, name)} of the last #{n} done #{plural(n, "card")}"

  defp subject(%{window: "all", name: name}, stream, _n), do: "All #{runs(stream.runs, name)}"
  defp subject(%{window: window, name: name}, stream, _n), do: "The #{runs(stream.runs, name)} in the last #{window}"

  defp runs(n, name), do: "#{n} #{name} #{plural(n, "run")}"

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

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
        id="value-stream-flow"
        class="flex min-w-0 flex-col gap-[18px] px-4 py-5 md:px-[30px] md:py-[26px]"
      >
        <.link
          id="vs-back"
          navigate={back_path(assigns)}
          class="self-start text-[12.5px] font-medium text-base-content/70 hover:text-base-content"
        >
          ← Card stream
        </.link>
        <div class="flex max-w-[1120px] flex-col gap-[5px]">
          <span
            id="vs-flow-eyebrow"
            style="font-size:10.5px;font-weight:700;letter-spacing:0.1em;font-family:var(--font-mono);color:color-mix(in oklab, var(--color-info) 70%, var(--color-base-content));"
          >
            LEVEL 2 · INSIDE ONE BOX
          </span>
          <h2
            id="vs-flow-title"
            style="font-size:20px;font-weight:600;margin:0;letter-spacing:-0.015em;"
          >
            {@name} flow · as-is
          </h2>
          <p
            id="vs-flow-explainer"
            style="font-size:13.5px;line-height:1.55;margin:0;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
          >
            {FlowLayout.explainer(@flow_layout, @flow.isolation)}
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
          <ValueStreamComponents.flow_legend runs={@view.stream.runs} />
          <div id="vs-flow-map" style="overflow-x:auto;max-width:100%;">
            <div style={"position:relative;width:#{@flow_layout.geometry.w}px;height:#{@flow_layout.geometry.h}px;"}>
              <ValueStreamComponents.flow_map
                layout={@flow_layout}
                arcs={@view.arcs}
                queue={@view.queue}
                terminals={@view.terminals}
              />
              <ValueStreamComponents.ladder
                id="vs-flow-ladder"
                items={@view.ladder_items}
                geometry={@flow_layout.geometry}
                fmt={&FlowLayout.fmt_minutes/1}
                label="TIME — each rung sits under the node it measures"
                footnote="a fix’s minutes are folded into the rung of the check that causes most of them"
              />
              <ValueStreamComponents.flow_node_box :for={box <- @view.boxes} box={box} />
            </div>
          </div>
          <ValueStreamComponents.run_lead_bands bands={@view.bands} />
          <div
            id="vs-tiles"
            class="grid grid-cols-2 gap-2.5 border-t border-base-300 pt-[18px] md:flex md:flex-wrap"
          >
            <ValueStreamComponents.stat_tile
              :for={t <- @view.tiles}
              id={t.id}
              label={t.label}
              value={t.value}
              sub={t.sub}
              tone={t.tone}
              hot={t.hot}
            />
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
