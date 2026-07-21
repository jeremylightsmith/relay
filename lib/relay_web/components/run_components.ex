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

  alias RelayWeb.RunStatus

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

  attr :detail, :map, required: true
  attr :baton, :string, required: true
  attr :now, :any, default: nil

  def run_status_strip(assigns) do
    now = assigns.now || DateTime.utc_now()
    detail = assigns.detail

    assigns =
      assigns
      |> assign(:now, now)
      |> assign(:styles, strip_styles(detail.status))
      |> assign(:title, strip_title(detail))
      |> assign(:elapsed, elapsed_label(detail, now))
      |> assign(:version_chip, version_chip(detail))

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

  # RLY-207: the parked suffix is bespoke to the strip; every other status
  # reads its label straight from the single status table. `cancelled` no
  # longer claims "claimed by a human" on the strip — that cause is only
  # data-backed on the drawer's :revoked banner (RunStatus.descriptor/1's
  # `label` states only what the status guarantees).
  defp strip_title(%{status: :parked}), do: RunStatus.descriptor(:parked).label <> " — waiting on your answer"
  defp strip_title(%{status: status}), do: RunStatus.descriptor(status).label

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

  attr :detail, :map, required: true
  attr :task_progress, :map, default: nil

  def run_node_timeline(assigns) do
    assigns = assign(assigns, :rows, assigns.detail.timeline)

    ~H"""
    <div class="run-node-timeline" style="display:flex;flex-direction:column;gap:6px;">
      <%= for row <- @rows do %>
        <%= case row.kind do %>
          <% :loop -> %>
            <div
              class="run-loop-chip"
              style="font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.09 65);background:oklch(0.98 0.03 75);border-radius:6px;padding:6px 10px;"
            >
              ↺ {loop_text(row)}
            </div>
          <% :pending -> %>
            <div
              class="run-timeline-row run-timeline-row-pending"
              style="display:flex;align-items:center;gap:10px;padding:8px 10px;color:oklch(0.60 0.02 255);"
            >
              <span style="display:inline-block;width:14px;height:14px;border-radius:50%;border:2px solid oklch(0.80 0.01 255);flex:0 0 auto;" />
              <span style="font-family:var(--font-mono);font-size:12px;">
                {Enum.join(row.nodes, " → ")}
              </span>
            </div>
          <% :node -> %>
            <.timeline_node_row row={row} task_progress={@task_progress} />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp loop_text(%{from_node: f, to_node: t, attempt: a, max_loops: nil}), do: "#{f} failed → #{t} · attempt #{a}"

  defp loop_text(%{from_node: f, to_node: t, attempt: a, max_loops: m}),
    do: "#{f} failed → #{t} · attempt #{a} · max #{m}"

  attr :row, :map, required: true
  attr :task_progress, :map, default: nil

  defp timeline_node_row(assigns) do
    ~H"""
    <div class="run-timeline-row" style="display:flex;flex-direction:column;gap:4px;">
      <div style="display:flex;align-items:center;gap:10px;">
        <.timeline_icon state={@row.state} />
        <span style="font-family:var(--font-mono);font-size:13.5px;font-weight:600;color:oklch(0.28 0.02 255);">
          {@row.node_key}
        </span>
        <span :if={@row.type} class={type_tag_class(@row.type)} style={type_tag_style(@row.type)}>
          {@row.type}
        </span>
        <span
          :if={@row.attempt > 1}
          class="run-attempt-chip"
          style="font-family:var(--font-mono);font-size:9.5px;color:oklch(0.55 0.02 255);background:oklch(0.95 0.006 255);border-radius:4px;padding:2px 6px;"
        >
          attempt {@row.attempt}
        </span>
        <span
          :if={@row.resumed?}
          class="run-resumed-chip"
          style="font-family:var(--font-mono);font-size:9.5px;color:oklch(0.46 0.12 292);background:oklch(0.97 0.03 292);border-radius:4px;padding:2px 6px;"
        >
          session resumed
        </span>
        <span
          :if={@row.partial?}
          style="font-family:var(--font-mono);font-size:9.5px;color:oklch(0.42 0.10 155);"
        >
          partial
        </span>
        <span style="margin-left:auto;font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.02 255);">
          {run_duration(@row.duration_s)}
        </span>
        <span style="font-family:var(--font-mono);font-size:11px;color:oklch(0.50 0.08 155);">
          {run_cost(@row.cost)}
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
        <pre style="background:oklch(0.20 0.02 255);color:oklch(0.94 0.006 255);font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;border-radius:6px;padding:8px 10px;margin:0;"><%= @row.detail %></pre>
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

  # ---------- run_state_banner ----------

  attr :variant, :atom, required: true, values: [:reentry, :revoked, :circuit, :failed, :parked]
  attr :detail, :map, default: nil
  attr :card, :any, default: nil
  attr :claimer, :string, default: nil
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
          <strong>{@detail.current_node}</strong>
          was cancelled. Nothing is lost — the branch {@card.branch} keeps the work so far.
        </p>
      </div>
    </div>
    """
  end

  def run_state_banner(%{variant: :circuit} = assigns) do
    assigns =
      assigns
      |> assign(:tripped, assigns.detail.tripped_node)
      |> assign(:repeats, assigns.detail.tripped_repeats)
      |> assign(:detail_text, assigns.detail.last_failure_detail)
      |> assign(:totals, assigns.detail.totals)

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
      <pre style="background:oklch(0.20 0.02 255);color:oklch(0.94 0.006 255);font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;border-radius:6px;padding:8px 10px;margin:0 0 10px 0;"><%= @detail_text %></pre>
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
      |> assign(:reason, assigns.detail.failure_reason)
      |> assign(:detail_text, assigns.detail.last_failure_detail)
      |> assign(:totals, assigns.detail.totals)

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
        :if={@detail_text}
        style="background:oklch(0.20 0.02 255);color:oklch(0.94 0.006 255);font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;border-radius:6px;padding:8px 10px;margin:0 0 10px 0;"
      ><%= @detail_text %></pre>
      <.failure_stats :if={@totals} totals={@totals} />
      <.retry_button />
    </div>
    """
  end

  def run_state_banner(%{variant: :parked} = assigns) do
    assigns = assign(assigns, :attempt, assigns.detail.parked_attempt)

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
          · paused at {@detail.current_node} · attempt {@attempt}
        </div>
        {render_slot(@inner_block)}
      </div>
      <div style="display:flex;align-items:center;gap:10px;padding:8px 10px;">
        <span style="display:flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:50%;background:var(--color-warning);color:oklch(1 0 0);font-size:9px;animation:relaypulse 1.6s ease-in-out infinite;">
          ?
        </span>
        <span style="font-family:var(--font-mono);font-size:12px;color:oklch(0.50 0.02 255);">
          Parked {ago(DateTime.utc_now(), @detail.started_at)}
        </span>
      </div>
    </div>
    """
  end

  # RLY-189 — the minimal Retry control on a terminally failed run's banner.
  #
  # Deliberately not designed: RLY-178 owns the human surface for run failure and
  # recovery. This ships the smallest usable affordance so the feature is usable
  # the day it merges. There is no `--at` picker — the CLI covers that case.
  #
  # The `:circuit` and `:failed` variants are mutually exclusive (`Relay.Runs.breaker_tripped?/1`
  # gates them), so the shared `run-retry` DOM id is never duplicated on a page.
  defp retry_button(assigns) do
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
            class={history_chip_class(entry.detail.status)}
            style={history_chip_style(entry.detail.status)}
          >
            {RunStatus.descriptor(entry.detail.status).label}
          </span>
          <span style="font-size:13px;font-weight:600;color:oklch(0.28 0.02 255);">
            {history_title(entry)}
          </span>
          <span style="margin-left:auto;font-size:11px;color:oklch(0.55 0.02 255);">
            {ago(DateTime.utc_now(), entry.detail.finished_at)}
          </span>
          <span style="color:oklch(0.60 0.02 255);">⌄</span>
        </summary>
        <div style="padding:0 12px 12px 12px;">
          <div style="display:flex;gap:18px;margin-bottom:10px;">
            <.stat
              label="DURATION"
              value={run_duration(entry.detail.totals.duration_s)}
              value_c={history_duration_color(entry.detail.status)}
            />
            <.stat label="NODES" value={"#{entry.detail.totals.nodes}"} />
            <.stat label="ATTEMPTS" value={"#{entry.detail.totals.attempts}"} />
            <.stat label="COST" value={run_cost(entry.detail.totals.cost)} />
          </div>
          <.run_node_timeline detail={entry.detail} />
        </div>
      </details>
    </div>
    """
  end

  defp history_title(%{number: number, detail: %{flow_version: nil}}), do: "Run ##{number}"
  defp history_title(%{number: number, detail: %{flow_version: v}}), do: "Run ##{number} · v#{v}"

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
  attr :progress_at, :any, default: nil
  attr :stalled?, :boolean, default: false

  def run_face(assigns) do
    assigns = assign(assigns, :state, face_state(assigns.run))

    ~H"""
    <div
      id={"card-#{@ref}-run-face"}
      class="run-face"
      data-run-state={@state}
      data-stalled={to_string(@stalled?)}
    >
      <.face_running
        :if={@state == :running}
        summary={run_summary(@run)}
        ref={@ref}
        progress_at={@progress_at}
        stalled?={@stalled?}
      />
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
  attr :ref, :string, required: true
  attr :progress_at, :any, default: nil
  attr :stalled?, :boolean, default: false

  defp face_running(assigns) do
    ~H"""
    <div
      class={["run-face-running", @stalled? && "run-face-stalled"]}
      style={
        "display:flex;flex-direction:column;gap:6px;" <>
          if(@stalled?,
            do: "background:oklch(0.97 0.03 75);border:1px solid oklch(0.88 0.06 75);border-radius:8px;padding:8px 10px;",
            else: ""
          )
      }
    >
      <div style="display:flex;gap:2px;">
        <span
          :for={i <- 1..(@summary.node_count || 1)}
          style={"flex:1;height:5px;border-radius:2px;#{face_segment_style(i, @summary)}"}
        />
      </div>
      <div style={"display:flex;align-items:center;gap:6px;font-family:var(--font-mono);font-size:11px;color:#{if(@stalled?, do: "oklch(0.48 0.11 65)", else: "oklch(0.44 0.12 292)")};"}>
        <span style={"width:6px;height:6px;border-radius:50%;background:#{if(@stalled?, do: "var(--color-warning)", else: "var(--color-secondary)")};#{unless @stalled?, do: "animation:relaypulse 1.6s ease-in-out infinite;"}"} />
        <span
          :if={not @stalled?}
          style="display:flex;align-items:center;justify-content:center;width:22px;height:22px;border-radius:50%;background:var(--color-secondary);animation:relayring 1.6s ease-out infinite;"
        /> node {@summary.node_index} of {@summary.node_count}
        <span style="flex:1;"></span>
        <span
          :if={@progress_at}
          id={"card-#{@ref}-run-age"}
          class="run-face-age"
          style="color:oklch(0.55 0.02 255);"
        >
          {ago(DateTime.utc_now(), @progress_at)}
        </span>
      </div>
      <div
        :if={@stalled?}
        class="run-face-stalled-note"
        style="font-family:var(--font-mono);font-size:10.5px;color:oklch(0.50 0.10 65);"
      >
        Quiet for a while — may be stuck
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
          {String.upcase(RunStatus.descriptor(:parked).label)} · NEEDS YOU
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
    assigns = assign(assigns, :circuit?, Map.get(assigns.summary, :breaker_tripped?, false))

    ~H"""
    <div
      class="run-face-badge run-face-failed"
      style="display:flex;align-items:center;gap:8px;background:oklch(0.975 0.03 22);border-radius:8px;padding:8px 10px;"
    >
      <span style={"display:flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:50%;background:var(#{RunStatus.descriptor(:failed).token});color:oklch(1 0 0);font-size:10px;"}>
        {RunStatus.descriptor(:failed).icon}
      </span>
      <div>
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.05em;color:oklch(0.52 0.16 22);">
          {String.upcase(RunStatus.descriptor(:failed).label)}
          <%= if @circuit? do %>
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
        {RunStatus.descriptor(:done).icon} {RunStatus.descriptor(:done).label} · {run_duration(
          @summary[:duration_s]
        )}
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
          {String.upcase(RunStatus.descriptor(:cancelled).label)}
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
