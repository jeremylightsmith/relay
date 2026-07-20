defmodule RelayWeb.RunComponents do
  @moduledoc """
  Run-visibility UI (ADR 0006 / RLY-137): the card drawer's Run tab pieces and
  the board card face's run affordances, matching
  `docs/designs/Relay Card Run Panel.dc.html` and
  `docs/designs/Relay Board Run Affordances.dc.html`. Self-contained on
  purpose — no CoreComponents import, so CoreComponents may render these
  without a compile cycle. Copy rule (ADR 0006): "session resumed" only after
  a needs-input re-entry, never after a review-failed loop.

  Field-name note (RLY-132 drift from the original plan): `Schemas.Run` has
  no `flow_version` column yet (RLY-152) and `Schemas.NodeExecution` names
  its node `node_key` (not `node`) and stores no `duration_s` (only
  `started_at`/`finished_at` — duration is the timestamp gap). Components
  here read `:node_key` and compute per-row duration from timestamps, but
  fall back to a `:duration_s` key first so plain test/story maps can supply
  it directly (mirrors `test/support/factory.ex`'s `:duration_s`
  convenience). `run`/summary maps carry `:flow_version` (nil until RLY-152
  ships versioning) — the version chip degrades gracefully when absent.
  """

  use Phoenix.Component

  # ---------- formatters (public: board_card and tests use them) ----------

  @doc ~s(`nil → "—"`, `8 → "0:08"`, `160 → "2:40"`, `4020 → "1h 7m"`.)
  def run_duration(nil), do: "—"

  def run_duration(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  def run_duration(seconds), do: "#{div(seconds, 3600)}h #{seconds |> rem(3600) |> div(60)}m"

  @doc ~s{`nil → "—"`, `Decimal/number → "$0.90"` (2 dp); never `$0.00` for missing cost.}
  def run_cost(nil), do: "—"
  def run_cost(%Decimal{} = cost), do: "$" <> (cost |> Decimal.round(2) |> Decimal.to_string(:normal))
  def run_cost(cost) when is_number(cost), do: "$#{:erlang.float_to_binary(cost / 1, decimals: 2)}"

  # ---------- run_status_strip ----------

  attr :run, :map, required: true
  attr :baton, :string, required: true
  attr :now, :any, default: nil

  def run_status_strip(assigns) do
    now = assigns.now || DateTime.utc_now()
    styles = strip_styles(assigns.run.status)

    assigns =
      assigns
      |> assign(:now, now)
      |> assign(:styles, styles)
      |> assign(:title, strip_title(assigns.run))
      |> assign(:elapsed, elapsed_label(assigns.run, now))
      |> assign(:version_chip, version_chip(assigns.run))

    ~H"""
    <div
      class="run-strip"
      style={"display:flex;align-items:center;justify-content:space-between;gap:14px;padding:12px 22px;background:#{@styles.wrap_bg};border-bottom:1px solid #{@styles.wrap_border};"}
    >
      <div style="display:flex;align-items:center;gap:12px;min-width:0;">
        <span
          class="run-strip-dot"
          style={"display:inline-block;width:8px;height:8px;border-radius:50%;background:#{@styles.dot};#{if @styles.pulse?, do: "animation:relaypulse 1.6s ease-in-out infinite;"}"}
        />
        <span
          class="run-strip-baton"
          style={"font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;text-transform:uppercase;background:#{@styles.baton_bg};color:#{@styles.baton_c};padding:3px 8px;border-radius:5px;flex:0 0 auto;"}
        >
          {@baton}
        </span>
        <span
          class="run-strip-title"
          style={"font-size:14px;font-weight:600;color:#{@styles.title_c};"}
        >
          {@title}
        </span>
      </div>
      <div style="display:flex;align-items:center;gap:10px;flex:0 0 auto;">
        <span
          class="run-strip-elapsed"
          style="font-family:var(--font-mono);font-size:11px;color:oklch(0.55 0.02 255);"
        >
          {@elapsed}
        </span>
        <span
          class="run-strip-version"
          style={"font-family:var(--font-mono);font-size:10px;font-weight:600;background:#{@styles.ver_bg};color:#{@styles.ver_c};padding:3px 8px;border-radius:5px;"}
        >
          {@version_chip}
        </span>
      </div>
    </div>
    """
  end

  defp strip_title(%{status: :running}), do: "Running"
  defp strip_title(%{status: :parked}), do: "Parked — waiting on your answer"
  # Neutral on purpose (RLY-179): the old copy claimed "circuit breaker tripped" for
  # every failure mode, which was false for both reported incidents. The specific
  # reason belongs to the failed-run panel (RLY-178).
  defp strip_title(%{status: :failed}), do: "Run failed"
  defp strip_title(%{status: :done}), do: "Completed"
  defp strip_title(%{status: :cancelled}), do: "Run cancelled — claimed by a human"

  defp version_chip(%{status: :running, flow_version: v}), do: version_label("running", v)
  defp version_chip(%{status: :running}), do: "running"

  defp version_chip(%{status: :parked, flow_key: k, flow_version: v}) do
    prefix = String.capitalize(k)
    if v, do: "#{prefix} · v#{v}", else: prefix
  end

  defp version_chip(%{status: :parked, flow_key: k}), do: String.capitalize(k)
  defp version_chip(%{status: :done, flow_version: v}), do: version_label("ran on", v)
  defp version_chip(%{status: :done}), do: "ran on"
  defp version_chip(%{flow_version: v}), do: version_label("was on", v)
  defp version_chip(_run), do: "was on"

  defp version_label(prefix, nil), do: prefix
  defp version_label(prefix, v), do: "#{prefix} v#{v}"

  defp elapsed_label(%{status: :running, started_at: at}, now), do: "elapsed #{clock(now, at)}"
  defp elapsed_label(%{status: :parked, started_at: at}, now), do: "parked #{clock(now, at)}"
  defp elapsed_label(%{status: :done, finished_at: at}, now), do: "finished #{ago(now, at)}"
  defp elapsed_label(%{status: :failed, finished_at: at}, now), do: "stopped #{ago(now, at)}"
  defp elapsed_label(%{status: :cancelled, finished_at: at}, now), do: "cancelled #{ago(now, at)}"

  defp clock(_now, nil), do: ""
  defp clock(now, at), do: run_duration(max(DateTime.diff(now, at, :second), 0))

  defp times_label(1), do: "1 time"
  defp times_label(n), do: "#{n} times"

  defp ago(_now, nil), do: ""

  defp ago(now, at) do
    seconds = max(DateTime.diff(now, at, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  # wrap/baton/dot/version colors per status — the artboard's `strips` table.
  defp strip_styles(:running),
    do: %{
      wrap_bg: "oklch(0.985 0.018 292)",
      wrap_border: "oklch(0.92 0.03 292)",
      baton_bg: "oklch(0.97 0.03 292)",
      baton_c: "oklch(0.46 0.14 292)",
      dot: "var(--color-secondary)",
      pulse?: true,
      title_c: "oklch(0.44 0.12 292)",
      ver_bg: "oklch(0.96 0.03 292)",
      ver_c: "oklch(0.46 0.13 292)"
    }

  defp strip_styles(:parked),
    do: %{
      wrap_bg: "oklch(0.985 0.022 75)",
      wrap_border: "oklch(0.90 0.05 75)",
      baton_bg: "oklch(0.98 0.04 75)",
      baton_c: "oklch(0.48 0.11 65)",
      dot: "var(--color-warning)",
      pulse?: false,
      title_c: "oklch(0.48 0.11 65)",
      ver_bg: "oklch(0.97 0.02 75)",
      ver_c: "oklch(0.50 0.09 65)"
    }

  defp strip_styles(:failed),
    do: %{
      wrap_bg: "oklch(0.985 0.02 22)",
      wrap_border: "oklch(0.91 0.04 22)",
      baton_bg: "oklch(0.97 0.03 22)",
      baton_c: "oklch(0.52 0.16 22)",
      dot: "var(--color-error)",
      pulse?: false,
      title_c: "oklch(0.50 0.14 22)",
      ver_bg: "oklch(0.97 0.02 22)",
      ver_c: "oklch(0.52 0.13 22)"
    }

  defp strip_styles(:cancelled),
    do: %{
      wrap_bg: "oklch(0.985 0.01 250)",
      wrap_border: "oklch(0.92 0.02 250)",
      baton_bg: "oklch(0.97 0.02 250)",
      baton_c: "oklch(0.44 0.13 250)",
      dot: "var(--color-accent)",
      pulse?: false,
      title_c: "oklch(0.44 0.06 250)",
      ver_bg: "oklch(0.97 0.02 250)",
      ver_c: "oklch(0.46 0.10 250)"
    }

  defp strip_styles(:done),
    do: %{
      wrap_bg: "oklch(0.985 0.015 155)",
      wrap_border: "oklch(0.92 0.03 155)",
      baton_bg: "oklch(0.97 0.03 155)",
      baton_c: "oklch(0.42 0.11 155)",
      dot: "var(--color-success)",
      pulse?: false,
      title_c: "oklch(0.42 0.10 155)",
      ver_bg: "oklch(0.97 0.02 155)",
      ver_c: "oklch(0.42 0.11 155)"
    }

  # ---------- run_mini_graph ----------

  attr :path, :list, required: true
  attr :run, :map, required: true
  attr :task_progress, :map, default: nil

  def run_mini_graph(assigns) do
    current_index = Enum.find_index(assigns.path, &(&1 == assigns.run.current_node))

    segments =
      assigns.path
      |> Enum.with_index()
      |> Enum.map(fn {node, index} -> {node, segment_state(index, current_index)} end)

    assigns =
      assigns
      |> assign(:segments, segments)
      |> assign(:header, mini_graph_header(assigns.run, assigns.task_progress))

    ~H"""
    <div class="run-mini-graph">
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.50 0.02 255);margin-bottom:6px;">
        {@header}
      </div>
      <div style="display:flex;gap:3px;">
        <span
          :for={{_node, state} <- @segments}
          class={"run-mini-graph-segment run-mini-graph-segment-#{state}"}
          style={segment_style(state)}
        />
      </div>
    </div>
    """
  end

  defp mini_graph_header(run, %{total: total} = task_progress) when total > 0 do
    "FLOW · #{String.upcase(run.flow_key)} · task #{task_progress.done + 1} of #{total}"
  end

  defp mini_graph_header(run, _task_progress), do: "FLOW · #{String.upcase(run.flow_key)}"

  defp segment_state(index, current_index) when is_integer(current_index) and index < current_index, do: :done
  defp segment_state(index, current_index) when is_integer(current_index) and index == current_index, do: :active
  defp segment_state(_index, _current_index), do: :pending

  defp segment_style(:done), do: "flex:1;height:9px;border-radius:3px;background:var(--color-success);"

  defp segment_style(:active) do
    "flex:1;height:9px;border-radius:3px;background:var(--color-secondary);" <>
      "animation:relaypulse 1.6s ease-in-out infinite;box-shadow:0 0 0 2px oklch(0.56 0.16 292/0.25);"
  end

  defp segment_style(:pending), do: "flex:1;height:9px;border-radius:3px;background:oklch(0.80 0.01 255);opacity:0.5;"

  # ---------- run_node_timeline ----------

  attr :run, :map, required: true
  attr :node_executions, :list, required: true
  attr :flow, :any, default: nil
  attr :task_progress, :map, default: nil

  def run_node_timeline(assigns) do
    assigns = assign(assigns, :rows, timeline_rows(assigns.run, assigns.node_executions, assigns.flow))

    ~H"""
    <div class="run-node-timeline" style="display:flex;flex-direction:column;gap:6px;">
      <%= for row <- @rows do %>
        <%= case row.kind do %>
          <% :loop -> %>
            <div
              class="run-loop-chip"
              style="font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.09 65);background:oklch(0.98 0.03 75);border-radius:6px;padding:6px 10px;"
            >
              ↺ {row.text}
            </div>
          <% :pending -> %>
            <div
              class="run-timeline-row run-timeline-row-pending"
              style="display:flex;align-items:center;gap:10px;padding:8px 10px;color:oklch(0.60 0.02 255);"
            >
              <span style="display:inline-block;width:14px;height:14px;border-radius:50%;border:2px solid oklch(0.80 0.01 255);flex:0 0 auto;" />
              <span style="font-family:var(--font-mono);font-size:12px;">{row.text}</span>
            </div>
          <% :node -> %>
            <.timeline_node_row row={row} task_progress={@task_progress} />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :task_progress, :map, default: nil

  defp timeline_node_row(assigns) do
    ~H"""
    <div class="run-timeline-row" style="display:flex;flex-direction:column;gap:4px;">
      <div style="display:flex;align-items:center;gap:10px;">
        <.timeline_icon state={@row.state} />
        <span style="font-family:var(--font-mono);font-size:13.5px;font-weight:600;color:oklch(0.28 0.02 255);">
          {@row.ne.node_key}
        </span>
        <span
          :if={@row.type_tag}
          class={type_tag_class(@row.type_tag)}
          style={type_tag_style(@row.type_tag)}
        >
          {@row.type_tag}
        </span>
        <span
          :if={@row.ne.attempt > 1}
          class="run-attempt-chip"
          style="font-family:var(--font-mono);font-size:9.5px;color:oklch(0.55 0.02 255);background:oklch(0.95 0.006 255);border-radius:4px;padding:2px 6px;"
        >
          attempt {@row.ne.attempt}
        </span>
        <span
          :if={@row.resumed?}
          class="run-resumed-chip"
          style="font-family:var(--font-mono);font-size:9.5px;color:oklch(0.46 0.12 292);background:oklch(0.97 0.03 292);border-radius:4px;padding:2px 6px;"
        >
          session resumed
        </span>
        <span
          :if={@row.ne.outcome == :partial}
          style="font-family:var(--font-mono);font-size:9.5px;color:oklch(0.42 0.10 155);"
        >
          partial
        </span>
        <span style="margin-left:auto;font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.02 255);">
          {run_duration(ne_duration_s(@row.ne))}
        </span>
        <span style="font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.08 155);">
          {run_cost(@row.ne.cost)}
        </span>
      </div>
      <div
        :if={@row.state == :active && @task_progress}
        style="height:5px;border-radius:3px;background:oklch(0.92 0.01 292);overflow:hidden;"
      >
        <div style={"height:100%;background:var(--color-secondary);width:#{task_progress_pct(@task_progress)}%;"} />
      </div>
      <div
        :if={@row.state == :failed}
        style="background:oklch(0.98 0.025 22);border-radius:8px;padding:8px 10px;"
      >
        <div style="font-family:var(--font-mono);font-size:9px;font-weight:700;letter-spacing:0.05em;color:oklch(0.52 0.16 22);margin-bottom:4px;">
          OUTCOME: FAILED
        </div>
        <pre style="background:oklch(0.20 0.02 255);color:oklch(0.94 0.006 255);font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;border-radius:6px;padding:8px 10px;margin:0;"><%= @row.ne.detail %></pre>
      </div>
    </div>
    """
  end

  attr :state, :atom, required: true

  defp timeline_icon(%{state: :done} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-success);color:oklch(1 0 0);font-size:11px;flex:0 0 auto;"
    >
      ✓
    </span>
    """
  end

  defp timeline_icon(%{state: :failed} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-error);color:oklch(1 0 0);font-size:11px;flex:0 0 auto;"
    >
      ✕
    </span>
    """
  end

  defp timeline_icon(%{state: :cancelled} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:oklch(0.90 0.006 255);color:oklch(0.55 0.02 255);font-size:11px;flex:0 0 auto;"
    >
      ⊘
    </span>
    """
  end

  defp timeline_icon(%{state: :stopped} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:5px;background:oklch(0.62 0.16 22);color:oklch(1 0 0);font-size:11px;flex:0 0 auto;"
    >
      ⊗
    </span>
    """
  end

  defp timeline_icon(%{state: :active} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-secondary);animation:relayring 1.6s ease-out infinite;flex:0 0 auto;"
    />
    """
  end

  defp timeline_icon(%{state: :paused} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-warning);color:oklch(1 0 0);font-size:11px;flex:0 0 auto;animation:relaypulse 1.6s ease-in-out infinite;"
    >
      ?
    </span>
    """
  end

  defp type_tag_class(:agent), do: "run-type-tag run-type-tag-agent"
  defp type_tag_class(:gate), do: "run-type-tag run-type-tag-gate"
  defp type_tag_class(_type), do: "run-type-tag run-type-tag-shell"

  defp type_tag_style(:agent),
    do:
      "font-family:var(--font-mono);font-size:8px;font-weight:700;text-transform:uppercase;" <>
        "background:oklch(0.96 0.03 292);color:oklch(0.46 0.13 292);border-radius:3px;padding:2px 5px;"

  defp type_tag_style(:gate),
    do:
      "font-family:var(--font-mono);font-size:8px;font-weight:700;text-transform:uppercase;" <>
        "background:oklch(0.97 0.03 75);color:oklch(0.50 0.09 65);border-radius:3px;padding:2px 5px;"

  defp type_tag_style(_type),
    do:
      "font-family:var(--font-mono);font-size:8px;font-weight:700;text-transform:uppercase;" <>
        "background:oklch(0.95 0.006 255);color:oklch(0.50 0.02 255);border-radius:3px;padding:2px 5px;"

  defp task_progress_pct(%{done: done, total: total}) when total > 0, do: min(100, round(done / total * 100))
  defp task_progress_pct(_task_progress), do: 0

  # Duration source, first match wins: a `:duration_s` key set directly (test
  # fixtures / stories, no DB round trip) else the started_at/finished_at
  # timestamp gap the real Schemas.NodeExecution row carries.
  defp ne_duration_s(%{duration_s: seconds}), do: seconds
  defp ne_duration_s(%{started_at: s, finished_at: f}) when not is_nil(s) and not is_nil(f), do: DateTime.diff(f, s)
  defp ne_duration_s(_ne), do: nil

  # Chronological fold. For each node execution:
  # * loop chip row BEFORE it when attempt > 1 and the chronologically
  #   previous execution ended :failed
  # * "session resumed" chip ONLY when this node's own previous attempt ended
  #   :needs_input (ADR rule — pinned by tests)
  # * a synthetic active row for run.current_node when the run is :running
  #   and no nil-outcome execution exists
  # * a collapsed pending tail when the run is :running/:parked and a flow is
  #   given: happy-path nodes not yet executed and not current
  defp timeline_rows(run, node_executions, flow) do
    node_rows =
      node_executions
      |> Enum.with_index()
      |> Enum.flat_map(fn {ne, index} ->
        prev = if index > 0, do: Enum.at(node_executions, index - 1)

        loop_row =
          if ne.attempt > 1 and prev != nil and prev.outcome == :failed do
            [%{kind: :loop, text: loop_text(prev, ne, flow)}]
          else
            []
          end

        loop_row ++
          [
            %{
              kind: :node,
              ne: ne,
              state: row_state(ne, run),
              resumed?: resumed?(ne, node_executions),
              type_tag: type_tag(ne.node_key, flow)
            }
          ]
      end)

    node_rows ++ synthetic_active(run, node_executions) ++ pending_tail(run, node_executions, flow)
  end

  defp row_state(%{outcome: :succeeded}, _run), do: :done
  defp row_state(%{outcome: :partial}, _run), do: :done
  defp row_state(%{outcome: :failed}, _run), do: :failed
  defp row_state(%{outcome: :needs_input}, _run), do: :paused
  defp row_state(%{outcome: nil}, %{status: :running}), do: :active
  defp row_state(%{outcome: nil}, %{status: :parked}), do: :paused
  defp row_state(%{outcome: nil}, %{status: :failed}), do: :stopped
  defp row_state(%{outcome: nil}, _run), do: :cancelled

  # ADR 0006 copy rule: "session resumed" ONLY when this node's own previous
  # attempt parked on needs_input. A review-failed loop is a fresh session.
  defp resumed?(%{attempt: attempt, node_key: node_key}, node_executions) when attempt > 1 do
    node_executions
    |> Enum.filter(&(&1.node_key == node_key and &1.attempt < attempt))
    |> List.last()
    |> case do
      %{outcome: :needs_input} -> true
      _other -> false
    end
  end

  defp resumed?(_ne, _node_executions), do: false

  defp loop_text(prev, ne, flow) do
    base = "#{prev.node_key} failed → #{ne.node_key} · attempt #{ne.attempt}"

    edge =
      flow && Enum.find(flow.edges, &(&1.from == prev.node_key and &1.on == :failed and &1.max_loops))

    if edge, do: base <> " · max #{edge.max_loops}", else: base
  end

  defp type_tag(node_key, %Schemas.Flow{nodes: nodes}),
    do: Enum.find_value(nodes, fn n -> n.key == node_key && n.type end)

  defp type_tag(_node_key, _flow), do: nil

  # The run is between nodes: no nil-outcome execution exists yet, so render
  # a synthetic active row for the engine's current node.
  defp synthetic_active(%{status: :running, current_node: node_key}, node_executions) when is_binary(node_key) do
    if Enum.any?(node_executions, &is_nil(&1.outcome)) do
      []
    else
      ne = %{node_key: node_key, attempt: 1, outcome: nil, detail: nil, cost: nil, started_at: nil, finished_at: nil}
      [%{kind: :node, ne: ne, state: :active, resumed?: false, type_tag: nil}]
    end
  end

  defp synthetic_active(_run, _node_executions), do: []

  defp pending_tail(%{status: status} = run, node_executions, %Schemas.Flow{} = flow)
       when status in [:running, :parked] do
    executed = MapSet.new(node_executions, & &1.node_key)

    remaining =
      flow
      |> Relay.Runs.happy_path()
      |> Enum.reject(&(MapSet.member?(executed, &1) or &1 == run.current_node))

    if remaining == [] do
      []
    else
      [%{kind: :pending, text: Enum.join(remaining, " → ")}]
    end
  end

  defp pending_tail(_run, _node_executions, _flow), do: []

  # ---------- run_state_banner ----------

  @doc """
  Whether a run died because the circuit breaker actually tripped.

  RLY-179: the breaker is ONE failure mode among several (`no_route_for_outcome`,
  `loop_budget_exhausted`, `visit_cap_exceeded`, …). `runs.failure_detail` carries
  the engine's reason verbatim (`RunServer.apply_decision/4` → `Runs.close_run!/3`),
  and the `circuit_breaker:` token has exactly one producer — `Engine.decide/4` — so
  it is the honest discriminator. Gating the loud `:circuit` banner on bare
  `status == :failed` made it claim a breaker for every failure, then contradict
  itself one line down with "fixit returned failed 1 time".

  Matched as a substring, not a prefix: the breaker reason is the one that leads
  with its machine token, while every sibling reason at `Engine`'s
  `no_route_reason/1` & co. is human-first with the token in parentheses. If the
  breaker string is ever brought in line with that house style, a prefix match
  would quietly stop recognising a real tripped breaker.
  """
  def circuit_tripped?(run) do
    case run do
      %{status: :failed, failure_detail: detail} when is_binary(detail) ->
        String.contains?(detail, "circuit_breaker:")

      _ ->
        false
    end
  end

  attr :variant, :atom, required: true, values: [:reentry, :revoked, :circuit, :failed, :parked]
  attr :run, :map, default: nil
  attr :card, :any, default: nil
  attr :claimer, :string, default: nil
  attr :node_executions, :list, default: []
  attr :totals, :map, default: nil
  slot :inner_block

  def run_state_banner(%{variant: :reentry} = assigns) do
    rejection = assigns.card.rejection
    assigns = assign(assigns, :rejection, rejection)

    ~H"""
    <div
      class="run-banner run-banner-reentry"
      style="border-left:3px solid oklch(0.60 0.14 250);background:oklch(0.975 0.02 250);border-radius:8px;padding:14px 16px;"
    >
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.44 0.10 250);margin-bottom:8px;">
        RE-ENTRY · CHANGES REQUESTED BY {String.upcase(@rejection.rejected_by)}
      </div>
      <blockquote style="margin:0 0 8px 0;padding:8px 10px;background:oklch(1 0 0 / 0.6);border-radius:6px;font-size:13px;color:oklch(0.32 0.02 255);">
        {@rejection.note}
      </blockquote>
      <div style="font-size:12px;color:oklch(0.50 0.02 255);">
        rejected from {@rejection.from_stage_name} {ago(DateTime.utc_now(), @rejection.rejected_at)}
      </div>
      <div style="font-size:12px;color:oklch(0.50 0.04 250);margin-top:4px;">
        the run reads this note before implement
      </div>
    </div>
    """
  end

  def run_state_banner(%{variant: :revoked} = assigns) do
    ~H"""
    <div class="run-banner run-banner-revoked" style="display:flex;flex-direction:column;gap:10px;">
      <div style="display:flex;align-items:center;gap:8px;font-family:var(--font-mono);font-size:11px;color:oklch(0.55 0.02 255);">
        <span style="width:8px;height:8px;border-radius:50%;background:var(--color-secondary);" />
        FLOW <span style="color:oklch(0.65 0.02 255);">→</span>
        <span style="display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:oklch(0.60 0.14 250);color:oklch(1 0 0);font-size:9px;">
          {initials(@claimer)}
        </span>
        {@claimer}
      </div>
      <div style="background:oklch(0.97 0.01 255);border-radius:8px;padding:12px 14px;">
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.40 0.02 255);margin-bottom:6px;">
          CLAIMED BY A HUMAN
        </div>
        <p style="font-size:13px;color:oklch(0.42 0.02 255);margin:0;">
          A human claimed this card while Relay AI was working, so the run at
          <strong>{@run.current_node}</strong>
          was cancelled. Nothing is lost — the branch {@card.branch} keeps the work so far.
        </p>
      </div>
    </div>
    """
  end

  def run_state_banner(%{variant: :circuit} = assigns) do
    tripped = tripped_node(assigns.run, assigns.node_executions)
    repeats = Enum.count(assigns.node_executions, &(&1.node_key == tripped and &1.outcome == :failed))

    assigns =
      assigns
      |> assign(:tripped, tripped)
      |> assign(:repeats, repeats)
      |> assign(:detail, last_failure_detail(assigns.node_executions))

    ~H"""
    <div
      class="run-banner run-banner-circuit"
      style="border-left:3px solid oklch(0.62 0.16 22);background:oklch(0.975 0.025 22);border-radius:8px;padding:14px 16px;"
    >
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.52 0.16 22);margin-bottom:6px;">
        ⊗ CIRCUIT BREAKER TRIPPED
      </div>
      <p style="font-size:13px;color:oklch(0.34 0.02 255);margin:0 0 8px 0;">
        <strong>{@tripped}</strong> returned failed {times_label(@repeats)}
      </p>
      <pre style="background:oklch(0.20 0.02 255);color:oklch(0.94 0.006 255);font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;border-radius:6px;padding:8px 10px;margin:0 0 10px 0;"><%= @detail %></pre>
      <.failure_stats totals={@totals} />
      <.retry_button />
    </div>
    """
  end

  # The honest banner for every failure mode that ISN'T a tripped breaker. Same red
  # frame, no invented cause: it leads with `runs.failure_detail` — the engine's
  # human-first sentence, which the Run tab surfaced nowhere before RLY-179.
  def run_state_banner(%{variant: :failed} = assigns) do
    assigns =
      assigns
      |> assign(:reason, failure_reason(assigns.run))
      |> assign(:detail, last_failure_detail(assigns.node_executions))

    ~H"""
    <div
      class="run-banner run-banner-failed"
      style="border-left:3px solid oklch(0.62 0.16 22);background:oklch(0.975 0.025 22);border-radius:8px;padding:14px 16px;"
    >
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.52 0.16 22);margin-bottom:6px;">
        ⊗ RUN FAILED
      </div>
      <p style="font-size:13px;color:oklch(0.34 0.02 255);margin:0 0 8px 0;">{@reason}</p>
      <pre
        :if={@detail}
        style="background:oklch(0.20 0.02 255);color:oklch(0.94 0.006 255);font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;border-radius:6px;padding:8px 10px;margin:0 0 10px 0;"
      ><%= @detail %></pre>
      <.failure_stats :if={@totals} totals={@totals} />
      <.retry_button />
    </div>
    """
  end

  def run_state_banner(%{variant: :parked} = assigns) do
    assigns = assign(assigns, :attempt, parked_attempt(assigns.run, assigns.node_executions))

    ~H"""
    <div class="run-banner run-banner-parked" style="display:flex;flex-direction:column;gap:10px;">
      <div style="display:flex;align-items:center;gap:8px;font-family:var(--font-mono);font-size:11px;color:oklch(0.55 0.02 255);">
        <span style="width:8px;height:8px;border-radius:50%;background:var(--color-warning);" />
        baton → <span style="font-weight:700;color:oklch(0.44 0.02 255);">YOU</span>
      </div>
      <div style="background:oklch(0.975 0.025 75);border-radius:8px;padding:14px 16px;">
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.48 0.11 65);margin-bottom:2px;">
          RELAY AI NEEDS YOUR INPUT
        </div>
        <div style="font-size:12px;color:oklch(0.55 0.06 65);margin-bottom:10px;">
          · paused at {@run.current_node} · attempt {@attempt}
        </div>
        {render_slot(@inner_block)}
      </div>
      <div style="display:flex;align-items:center;gap:10px;padding:8px 10px;">
        <span style="display:flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:50%;background:var(--color-warning);color:oklch(1 0 0);font-size:9px;animation:relaypulse 1.6s ease-in-out infinite;">
          ?
        </span>
        <span style="font-family:var(--font-mono);font-size:12px;color:oklch(0.50 0.02 255);">
          Parked {ago(DateTime.utc_now(), @run.started_at)}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  RLY-189 — the minimal Retry control on a terminally failed run's banner.

  Deliberately not designed: RLY-178 owns the human surface for run failure and
  recovery. This ships the smallest usable affordance so the feature is usable
  the day it merges. There is no `--at` picker — the CLI covers that case.

  The `:circuit` and `:failed` variants are mutually exclusive (`circuit_tripped?/1`
  gates them), so the shared `run-retry` DOM id is never duplicated on a page.
  """
  def retry_button(assigns) do
    ~H"""
    <button
      id="run-retry"
      type="button"
      class="btn btn-sm btn-primary"
      phx-click="retry_run"
      style="margin-top:10px;"
    >
      Retry
    </button>
    """
  end

  attr :totals, :map, required: true

  defp failure_stats(assigns) do
    ~H"""
    <div style="display:flex;gap:18px;">
      <.stat label="ATTEMPTS" value={"#{@totals.attempts} · stopped"} value_c="oklch(0.52 0.16 22)" />
      <.stat label="DURATION" value={run_duration(@totals.duration_s)} />
      <.stat label="SPENT" value={run_cost(@totals.cost)} />
    </div>
    """
  end

  defp last_failure_detail(node_executions) do
    node_executions
    |> Enum.filter(&(&1.outcome == :failed))
    |> List.last()
    |> then(&(&1 && &1.detail))
  end

  # `failure_detail` is the engine's human-first sentence; older runs (and any close
  # path that didn't record one) fall back to plain, non-committal copy rather than
  # guessing at a cause.
  defp failure_reason(%{failure_detail: reason}) when is_binary(reason), do: reason
  defp failure_reason(_run), do: "The run stopped before reaching the end of the flow."

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :value_c, :string, default: "oklch(0.30 0.02 255)"

  defp stat(assigns) do
    ~H"""
    <div>
      <div style="font-family:var(--font-mono);font-size:9px;font-weight:600;letter-spacing:0.05em;color:oklch(0.58 0.02 255);">
        {@label}
      </div>
      <div style={"font-family:var(--font-mono);font-size:13px;color:#{@value_c};"}>{@value}</div>
    </div>
    """
  end

  defp initials(nil), do: ""

  defp initials(name) do
    name
    |> String.split(" ", trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  # attempt shown on the parked banner = the highest recorded attempt for
  # the paused node (`run.current_node`); falls back to 1 when there's no
  # matching execution row on hand (e.g. node_executions not preloaded).
  defp parked_attempt(%{current_node: nil}, _node_executions), do: 1

  defp parked_attempt(%{current_node: node_key}, node_executions) do
    node_executions
    |> Enum.filter(&(&1.node_key == node_key))
    |> Enum.map(& &1.attempt)
    |> case do
      [] -> 1
      attempts -> Enum.max(attempts)
    end
  end

  # circuit helpers: tripped node = the node of the last :failed execution
  # (authoritative — a closed run's `current_node` is nilled by the engine's
  # `close_run!`), falling back to `run.current_node` when no failed
  # execution is on hand; repeat count = failed attempts of that node.
  defp tripped_node(run, node_executions) do
    node_executions
    |> Enum.filter(&(&1.outcome == :failed))
    |> List.last()
    |> case do
      %{node_key: node_key} -> node_key
      _other -> Map.get(run, :current_node)
    end
  end

  # ---------- run_history ----------

  attr :runs, :list, required: true

  def run_history(assigns) do
    ~H"""
    <div class="run-history">
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:oklch(0.50 0.02 255);margin-bottom:8px;">
        PRIOR RUNS · {length(@runs)}
      </div>
      <details
        :for={entry <- @runs}
        class="run-history-entry"
        style="border:1px solid oklch(0.92 0.006 255);border-radius:8px;margin-bottom:8px;"
      >
        <summary style="display:flex;align-items:center;gap:10px;padding:10px 12px;cursor:pointer;list-style:none;">
          <span
            class={history_chip_class(entry.run.status)}
            style={history_chip_style(entry.run.status)}
          >
            {history_status_label(entry.run.status)}
          </span>
          <span style="font-size:13px;font-weight:600;color:oklch(0.28 0.02 255);">
            {history_title(entry)}
          </span>
          <span style="margin-left:auto;font-size:11px;color:oklch(0.55 0.02 255);">
            {ago(DateTime.utc_now(), entry.run.finished_at)}
          </span>
          <span style="color:oklch(0.60 0.02 255);">⌄</span>
        </summary>
        <div style="padding:0 12px 12px 12px;">
          <div style="display:flex;gap:18px;margin-bottom:10px;">
            <.stat
              label="DURATION"
              value={run_duration(entry.totals.duration_s)}
              value_c={history_duration_color(entry.run.status)}
            />
            <.stat label="NODES" value={"#{entry.totals.nodes}"} />
            <.stat label="ATTEMPTS" value={"#{entry.totals.attempts}"} />
            <.stat label="COST" value={run_cost(entry.totals.cost)} />
          </div>
          <.run_node_timeline run={entry.run} node_executions={entry.node_executions} />
        </div>
      </details>
    </div>
    """
  end

  defp history_title(%{number: number, run: %{flow_version: nil}}), do: "Run ##{number}"
  defp history_title(%{number: number, run: %{flow_version: v}}), do: "Run ##{number} · v#{v}"

  defp history_status_label(:done), do: "completed"
  defp history_status_label(status), do: Atom.to_string(status)

  defp history_chip_class(:done), do: "run-history-chip run-history-chip-done"
  defp history_chip_class(_status), do: "run-history-chip run-history-chip-failed"

  defp history_chip_style(:done),
    do:
      "font-family:var(--font-mono);font-size:9px;font-weight:700;text-transform:uppercase;" <>
        "background:oklch(0.97 0.03 155);color:oklch(0.42 0.10 155);border-radius:4px;padding:2px 6px;"

  defp history_chip_style(_status),
    do:
      "font-family:var(--font-mono);font-size:9px;font-weight:700;text-transform:uppercase;" <>
        "background:oklch(0.97 0.03 22);color:oklch(0.52 0.13 22);border-radius:4px;padding:2px 6px;"

  defp history_duration_color(:failed), do: "oklch(0.52 0.14 22)"
  defp history_duration_color(_status), do: "oklch(0.30 0.02 255)"

  # ---------- run_face (board card) ----------

  attr :run, :any, required: true
  attr :ref, :string, required: true

  def run_face(assigns) do
    assigns = assign(assigns, :state, face_state(assigns.run))

    ~H"""
    <div id={"card-#{@ref}-run-face"} class="run-face" data-run-state={@state}>
      <.face_running :if={@state == :running} summary={run_summary(@run)} />
      <.face_parked :if={@state == :parked} summary={run_summary(@run)} />
      <.face_failed :if={@state == :failed} summary={run_summary(@run)} />
      <.face_queued :if={@state == :queued} flow={run_summary(@run)} />
      <.face_done :if={@state == :done} summary={run_summary(@run)} />
      <.face_cancelled :if={@state == :cancelled} summary={run_summary(@run)} />
      <.face_review :if={@state == :review} summary={run_summary(@run)} />
    </div>
    """
  end

  def face_state({:review, _summary}), do: :review
  def face_state({:queued, _flow}), do: :queued
  def face_state({:run, %{status: :done}}), do: :done
  def face_state({:run, %{status: status}}), do: status

  defp run_summary({:run, summary}), do: summary
  defp run_summary({:queued, flow}), do: flow
  defp run_summary({:review, summary}), do: summary

  attr :summary, :map, required: true

  defp face_running(assigns) do
    ~H"""
    <div class="run-face-running" style="display:flex;flex-direction:column;gap:6px;">
      <div style="display:flex;gap:2px;">
        <span
          :for={i <- 1..(@summary.node_count || 1)}
          style={"flex:1;height:5px;border-radius:2px;#{face_segment_style(i, @summary)}"}
        />
      </div>
      <div style="display:flex;align-items:center;gap:6px;font-family:var(--font-mono);font-size:11px;color:oklch(0.44 0.12 292);">
        <span style="width:6px;height:6px;border-radius:50%;background:var(--color-secondary);animation:relaypulse 1.6s ease-in-out infinite;" />
        <span style="display:flex;align-items:center;justify-content:center;width:22px;height:22px;border-radius:50%;background:var(--color-secondary);animation:relayring 1.6s ease-out infinite;" />
        node {@summary.node_index} of {@summary.node_count}
      </div>
    </div>
    """
  end

  defp face_segment_style(i, %{node_index: idx}) when is_integer(idx) and i < idx,
    do: "background:var(--color-secondary);"

  defp face_segment_style(i, %{node_index: idx}) when is_integer(idx) and i == idx,
    do: "background:var(--color-secondary);animation:relaypulse 1.6s ease-in-out infinite;"

  defp face_segment_style(_i, _summary), do: "background:oklch(0.90 0.02 292);"

  attr :summary, :map, required: true

  defp face_parked(assigns) do
    ~H"""
    <div
      class="run-face-badge run-face-parked"
      style="display:flex;align-items:center;gap:8px;background:oklch(0.975 0.025 75);border-radius:8px;padding:8px 10px;"
    >
      <span style="display:flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:50%;background:var(--color-warning);color:oklch(1 0 0);font-size:9px;animation:relaypulse 1.6s ease-in-out infinite;">
        ?
      </span>
      <div>
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.05em;color:oklch(0.48 0.11 65);">
          PARKED · NEEDS YOU
        </div>
        <div style="font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.06 65);">
          {@summary.current_node}
        </div>
      </div>
    </div>
    """
  end

  attr :summary, :map, required: true

  defp face_failed(assigns) do
    circuit? = (assigns.summary[:attempts] || 0) >= 3
    assigns = assign(assigns, :circuit?, circuit?)

    ~H"""
    <div
      class="run-face-badge run-face-failed"
      style="display:flex;align-items:center;gap:8px;background:oklch(0.975 0.03 22);border-radius:8px;padding:8px 10px;"
    >
      <span style="display:flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:50%;background:var(--color-error);color:oklch(1 0 0);font-size:10px;">
        !
      </span>
      <div>
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.05em;color:oklch(0.52 0.16 22);">
          RUN FAILED<%= if @circuit? do %>
            · CIRCUIT BREAKER
          <% end %>
        </div>
        <div style="font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.09 22);">
          stuck at {@summary.last_node}
          <%= if @summary[:flow_version] do %>
            · v{@summary.flow_version}
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :flow, :map, required: true

  defp face_queued(assigns) do
    ~H"""
    <div
      class="run-face-badge run-face-queued"
      style="display:flex;flex-direction:column;gap:2px;background:oklch(0.97 0.03 292);border-radius:8px;padding:8px 10px;"
    >
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.05em;color:oklch(0.46 0.13 292);">
        QUEUED · {String.upcase(@flow.key)} FLOW
      </div>
      <div style="font-family:var(--font-mono);font-size:11px;color:oklch(0.55 0.06 292);">
        picks up next
      </div>
    </div>
    """
  end

  attr :summary, :map, required: true

  defp face_done(assigns) do
    ~H"""
    <div
      class="run-face-row run-face-done"
      style="display:flex;align-items:center;justify-content:space-between;gap:8px;"
    >
      <span style="font-family:var(--font-mono);font-size:11px;color:oklch(0.42 0.10 155);">
        ✓ merged · {run_duration(@summary[:duration_s])}
      </span>
      <span style="font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.08 155);">
        {run_cost(@summary[:cost])}
      </span>
    </div>
    """
  end

  attr :summary, :map, required: true

  defp face_cancelled(assigns) do
    ~H"""
    <div
      class="run-face-badge run-face-cancelled"
      style="display:flex;align-items:center;gap:8px;background:oklch(0.97 0.006 255);border-radius:8px;padding:8px 10px;"
    >
      <span style="display:flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:50%;background:oklch(0.72 0.02 255);color:oklch(1 0 0);font-size:10px;">
        ⊘
      </span>
      <div>
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.05em;color:oklch(0.44 0.02 255);">
          CANCELLED · CLAIMED
        </div>
        <div style="font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.02 255);">
          stopped at {@summary.last_node} · resumable
        </div>
      </div>
    </div>
    """
  end

  # RLY-137 Task 4: a :done run on an :in_review card — the run landed the card in the
  # review lane and it's now human territory (docs/designs/Relay Board Run Affordances.dc.html
  # panel D). board_card/1 computes the {:review, summary} shape; the face tuple alone
  # can't tell (it doesn't know the card's current status).
  attr :summary, :map, required: true

  defp face_review(assigns) do
    ~H"""
    <div
      class="run-face-badge run-face-review"
      style="display:flex;align-items:center;gap:6px;background:oklch(0.97 0.02 250);border:1px solid oklch(0.89 0.04 250);border-radius:6px;padding:6px 8px;"
    >
      <span style="width:15px;height:15px;border-radius:50%;background:oklch(0.60 0.14 250);color:oklch(1 0 0);display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:700;flex:0 0 auto;">
        ✓
      </span>
      <span style="font-size:10.5px;font-weight:600;letter-spacing:0.03em;color:oklch(0.44 0.13 250);font-family:var(--font-mono);">
        READY FOR YOUR REVIEW
      </span>
    </div>
    """
  end
end
