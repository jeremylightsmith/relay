defmodule RelayWeb.FlowMetricsLive do
  @moduledoc "Per-flow metrics tab — the read surface over node_executions (RLY-209)."
  use RelayWeb, :live_view

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Runs
  alias RelayWeb.FlowEditorComponents
  alias RelayWeb.FlowMetricsComponents

  @impl true
  def mount(%{"slug" => slug, "key" => key}, _session, socket) do
    board = Boards.get_board!(socket.assigns.current_scope.user, slug)

    case Flows.get_flow(board, key) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That flow doesn't exist.")
         |> push_navigate(to: ~p"/board/#{slug}/settings?section=flows")}

      flow ->
        {:ok,
         socket
         |> assign(:page_title, "Flow metrics — #{humanize(flow.key)}")
         |> assign(:board, board)
         |> assign(:flow, flow)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    flow = socket.assigns.flow
    window = normalize_window(params["window"])
    summary = Runs.flow_metrics_summary(flow, window: window)
    rows = flow |> Runs.node_metrics_for_flow(window: window) |> present_rows(flow)

    {:noreply,
     socket
     |> assign(:window, window)
     |> assign(:deep_node, params["node"])
     |> assign(:deep_ref, params["from"])
     |> assign(:summary, summary)
     |> assign(:rows, rows)
     |> assign(:enough?, summary.completed >= Runs.min_runs_for_percentiles())
     |> assign(:cost_blank?, is_nil(summary.total_spend))}
  end

  @impl true
  def handle_event("set-window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: window_path(socket.assigns, normalize_window(window)))}
  end

  defp window_path(%{board: board, flow: flow, deep_node: node, deep_ref: ref}, window) do
    ~p"/board/#{board.slug}/flows/#{flow.key}/metrics?#{window_params(window, node, ref)}"
  end

  defp window_params(window, node, ref) do
    [{"window", window}]
    |> maybe_put("node", node)
    |> maybe_put("from", ref)
  end

  defp maybe_put(list, _k, nil), do: list
  defp maybe_put(list, k, v), do: list ++ [{k, v}]

  defp normalize_window(window) do
    if window in Runs.metric_windows(), do: window, else: Runs.default_window()
  end

  defp present_rows(metrics, flow) do
    defs = Map.new(flow.nodes, &{&1.key, &1})

    Enum.map(metrics, fn m ->
      node = Map.get(defs, m.node_key)

      Map.merge(m, %{
        name: humanize(m.node_key),
        type: node && node.type,
        model: node && node.model,
        verdict: collapse_verdict(m.verdict_split)
      })
    end)
  end

  # The bar has 3 buckets; :partial (progress handed back without clearing the node) collapses
  # into failed — a visit that neither succeeded nor asked a question did not clear the node.
  defp collapse_verdict(%{succeeded: ok, failed: fail, partial: partial, needs_input: needs}) do
    fail_total = fail + partial
    total = ok + needs + fail_total

    %{
      ok: ok,
      needs: needs,
      fail: fail_total,
      total: total,
      ok_pct: pct(ok, total),
      needs_pct: pct(needs, total),
      fail_pct: pct(fail_total, total)
    }
  end

  defp pct(_n, 0), do: 0
  defp pct(n, total), do: round(n * 100 / total)

  defp humanize(key), do: String.replace(key, ["_", "-"], " ")

  defp duration_cell(nil), do: "—"
  defp duration_cell(seconds) when seconds < 60, do: "#{seconds}s"

  defp duration_cell(seconds) do
    case rem(seconds, 60) do
      0 -> "#{div(seconds, 60)}m"
      r -> "#{div(seconds, 60)}m #{r}s"
    end
  end

  defp cost_cell(nil), do: "—"
  defp cost_cell(%Decimal{} = d), do: "$" <> Decimal.to_string(d, :normal)

  # Artboard type-tag palette (docs/designs/Relay Flow Metrics.dc.html lines 281-285).
  defp type_tag_style(:agent), do: "background:oklch(0.96 0.03 292);color:oklch(0.46 0.13 292);"
  defp type_tag_style(:shell), do: "background:oklch(0.96 0.004 255);color:oklch(0.50 0.02 255);"
  defp type_tag_style(:gate), do: "background:oklch(0.97 0.03 75);color:oklch(0.48 0.11 65);"
  defp type_tag_style(_), do: "background:oklch(0.96 0.004 255);color:oklch(0.50 0.02 255);"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide crumb>
      <div style="padding:22px 26px;max-width:1100px;">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:18px;">
          <nav style="font-size:13px;display:flex;align-items:center;gap:7px;">
            <.link
              navigate={~p"/board/#{@board.slug}"}
              style="color:oklch(0.52 0.02 255);font-weight:600;"
            >
              {@board.name}
            </.link>
            <span style="color:oklch(0.78 0.02 255);">/</span>
            <.link
              navigate={~p"/board/#{@board.slug}/settings?section=flows"}
              style="color:oklch(0.52 0.02 255);font-weight:600;"
            >
              Flows
            </.link>
            <span style="color:oklch(0.78 0.02 255);">/</span>
            <span style="color:oklch(0.28 0.02 255);font-weight:600;">{humanize(@flow.key)}</span>
          </nav>
          <FlowEditorComponents.flow_tabs
            board_slug={@board.slug}
            flow_key={@flow.key}
            active={:metrics}
          />
        </div>

        <%!-- Deep-link banner (RLY-209 decision 5) --%>
        <div
          :if={@deep_ref}
          id="deep-link-banner"
          style="background:oklch(0.975 0.02 250);border:1px solid oklch(0.88 0.05 250);border-left:3px solid oklch(0.60 0.14 250);border-radius:11px;padding:13px 16px;margin-bottom:16px;font-size:13px;"
        >
          Opened from <span style="font-family:var(--font-mono);font-weight:600;">{@deep_ref}</span>
          <%= if @deep_node do %>
            — jumped to <span style="font-family:var(--font-mono);font-weight:600;">{@deep_node}</span>,
            the node this card's run is on.
          <% end %>
        </div>

        <div style="margin-bottom:8px;">
          <h1
            id="flow-metrics-title"
            style="font-size:22px;font-weight:600;letter-spacing:-0.02em;color:oklch(0.24 0.02 255);"
          >
            Flow metrics
          </h1>
          <p style="font-size:13.5px;line-height:1.55;color:oklch(0.50 0.02 255);max-width:560px;">
            Per-node rollup for the <strong>{humanize(@flow.key)}</strong>
            flow. Every node execution records duration, attempts, verdict and cost — this is where
            you read it in aggregate and decide what to tune.
          </p>
        </div>

        <div style="display:flex;align-items:center;justify-content:space-between;margin:14px 0;">
          <span
            id="flow-metrics-version-chip"
            style="font-family:var(--font-mono);font-size:14px;font-weight:600;padding:6px 12px;border-radius:8px;background:oklch(0.96 0.004 255);color:oklch(0.34 0.02 255);"
          >
            v{@flow.version}
          </span>
          <div
            id="flow-metrics-window"
            style="display:inline-flex;background:oklch(0.96 0.004 255);border:1px solid oklch(0.90 0.006 255);border-radius:9px;padding:3px;gap:2px;"
          >
            <button
              :for={{key, label} <- window_options()}
              id={"flow-metrics-window-#{key}"}
              type="button"
              phx-click="set-window"
              phx-value-window={key}
              style={window_button_style(@window == key)}
            >
              {label}
            </button>
          </div>
        </div>

        <%!-- Stat band --%>
        <div style="display:grid;grid-template-columns:repeat(4,1fr);border:1px solid oklch(0.92 0.006 255);border-radius:12px;background:oklch(1 0 0);margin-bottom:18px;">
          <.stat_cell id="stat-total-runs" label="TOTAL RUNS" value={"#{@summary.total_runs}"} />
          <.stat_cell
            id="stat-completed"
            label="COMPLETED"
            value={"#{@summary.completed} · #{@summary.completed_pct}%"}
          />
          <.stat_cell
            id="stat-total-spend"
            label="TOTAL SPEND"
            value={cost_cell(@summary.total_spend)}
            muted={is_nil(@summary.total_spend)}
          />
          <.stat_cell
            id="stat-median"
            label="MEDIAN END-TO-END"
            value={duration_cell(@summary.median_end_to_end)}
            last
          />
        </div>

        <%!-- Cost-blank note (the only allowed insight text — decision 3) --%>
        <p
          :if={@cost_blank?}
          id="cost-blank-note"
          style="font-size:12px;color:oklch(0.52 0.02 255);margin-bottom:12px;"
        >
          Cost lights up once executors report spend. Duration, attempts and verdicts are recording live right now.
        </p>

        <%= if @enough? do %>
          <div
            id="flow-metrics-table"
            style="border:1px solid oklch(0.92 0.006 255);border-radius:12px;overflow:hidden;"
          >
            <div style="display:grid;grid-template-columns:minmax(220px,1.3fr) 62px 130px 130px 92px 170px 84px;column-gap:14px;padding:10px 16px;background:oklch(0.975 0.004 255);font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.55 0.02 255);">
              <span>NODE</span>
              <span style="text-align:right;">RUNS</span>
              <span style="text-align:right;">DURATION</span>
              <span style="text-align:right;">COST</span>
              <span style="text-align:right;">ATTEMPTS</span>
              <span>VERDICT SPLIT</span>
              <span style="text-align:right;">LOOP-LAPS</span>
            </div>
            <div
              :for={row <- @rows}
              id={"node-row-#{row.node_key}"}
              style={row_style(@deep_node == row.node_key)}
            >
              <div>
                <div style="display:flex;align-items:center;gap:8px;">
                  <span style="font-family:var(--font-mono);font-size:13px;font-weight:600;color:oklch(0.28 0.02 255);">
                    {row.name}
                  </span>
                  <span
                    :if={@deep_node == row.node_key}
                    id={"node-here-#{row.node_key}"}
                    style="font-family:var(--font-mono);font-size:9px;font-weight:600;color:oklch(0.44 0.13 250);background:oklch(0.95 0.03 250);border-radius:5px;padding:2px 6px;"
                  >
                    {@deep_ref} is here
                  </span>
                </div>
                <div style="display:flex;align-items:center;gap:6px;margin-top:3px;">
                  <span
                    id={"node-type-#{row.node_key}"}
                    style={"font-family:var(--font-mono);font-size:8.5px;font-weight:700;letter-spacing:0.06em;padding:2px 6px;border-radius:4px;#{type_tag_style(row.type)}"}
                  >
                    {row.type}
                  </span>
                  <span
                    :if={row.model}
                    id={"node-model-#{row.node_key}"}
                    style="font-family:var(--font-mono);font-size:10.5px;font-weight:500;color:oklch(0.44 0.10 292);background:oklch(0.975 0.02 292);padding:2px 7px;border-radius:4px;"
                  >
                    {row.model}
                  </span>
                </div>
              </div>
              <span style="text-align:right;font-family:var(--font-mono);font-size:13px;">
                {row.runs}
              </span>
              <span style="text-align:right;font-family:var(--font-mono);font-size:13px;">
                {duration_cell(row.duration_p50)} / {duration_cell(row.duration_p95)}
              </span>
              <span style="text-align:right;font-family:var(--font-mono);font-size:13px;">
                {cost_cell(row.cost_p50)} / {cost_cell(row.cost_p95)}
              </span>
              <span style="text-align:right;font-family:var(--font-mono);font-size:13px;">
                {:erlang.float_to_binary(row.attempts_mean, decimals: 1)}
              </span>
              <FlowMetricsComponents.verdict_bar id={"verdict-#{row.node_key}"} split={row.verdict} />
              <span style="text-align:right;font-family:var(--font-mono);font-size:13px;">
                {row.loop_laps}
              </span>
            </div>
          </div>
        <% else %>
          <div
            id="flow-metrics-empty"
            style="text-align:center;padding:54px 24px 58px 24px;border:1px solid oklch(0.92 0.006 255);border-radius:12px;"
          >
            <div style="font-size:16px;font-weight:600;color:oklch(0.34 0.02 255);">
              Not enough runs in this window yet
            </div>
            <p style="font-size:13px;color:oklch(0.50 0.02 255);max-width:460px;margin:8px auto 16px;">
              Only <strong>{@summary.completed} runs</strong>
              completed in this window. Per-node percentiles need roughly
              <strong>{Runs.min_runs_for_percentiles()}+</strong>
              completed runs before they're worth trusting.
            </p>
            <button
              id="widen-to-all"
              type="button"
              phx-click="set-window"
              phx-value-window="all"
              style="background:oklch(0.60 0.14 250);color:oklch(1 0 0);border:none;border-radius:8px;padding:9px 16px;font-size:13px;font-weight:600;"
            >
              Widen to all-time
            </button>
          </div>
        <% end %>

        <p
          id="flow-metrics-footnote"
          style="font-size:11.5px;color:oklch(0.56 0.02 255);margin-top:14px;"
        >
          <span style="font-family:var(--font-mono);color:oklch(0.62 0.02 255);">RUNS</span>
          count node executions, not cards — a node visited twice by one card counts twice.
          Per-card totals live in the card's Run panel.
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp window_options do
    Enum.map(Runs.metric_windows(), fn
      "7d" -> {"7d", "7 days"}
      "30d" -> {"30d", "30 days"}
      "all" -> {"all", "All time"}
    end)
  end

  defp window_button_style(true),
    do:
      "font-size:12px;padding:5px 11px;border:none;border-radius:7px;font-weight:600;cursor:pointer;" <>
        "background:oklch(1 0 0);color:oklch(0.28 0.02 255);box-shadow:0 1px 2px oklch(0.5 0.03 255/0.14);"

  defp window_button_style(false),
    do:
      "font-size:12px;padding:5px 11px;border:none;border-radius:7px;font-weight:600;cursor:pointer;background:transparent;color:oklch(0.52 0.02 255);"

  defp row_style(true),
    do:
      "display:grid;grid-template-columns:minmax(220px,1.3fr) 62px 130px 130px 92px 170px 84px;" <>
        "column-gap:14px;align-items:center;padding:12px 16px;border-top:1px solid oklch(0.95 0.005 255);" <>
        "background:oklch(0.975 0.02 250);box-shadow:inset 3px 0 0 oklch(0.60 0.14 250);"

  defp row_style(false),
    do:
      "display:grid;grid-template-columns:minmax(220px,1.3fr) 62px 130px 130px 92px 170px 84px;" <>
        "column-gap:14px;align-items:center;padding:12px 16px;border-top:1px solid oklch(0.95 0.005 255);"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :muted, :boolean, default: false
  attr :last, :boolean, default: false

  defp stat_cell(assigns) do
    ~H"""
    <div style={"padding:14px 16px;#{unless @last, do: "border-right:1px solid oklch(0.94 0.005 255);"}"}>
      <div style="font-family:var(--font-mono);font-size:9.5px;color:oklch(0.60 0.02 255);">
        {@label}
      </div>
      <div
        id={@id}
        style={"font-size:21px;font-weight:600;font-family:var(--font-mono);color:#{if @muted, do: "oklch(0.74 0.01 255)", else: "oklch(0.30 0.02 255)"};"}
      >
        {@value}
      </div>
    </div>
    """
  end
end
