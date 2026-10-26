defmodule HamacaWeb.RunComponents do
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
  ships versioning) — `run_list` omits an entry's `vX` when it is absent.
  """

  use Phoenix.Component

  alias Hamaca.Runs
  alias Hamaca.Runs.RunDetail
  alias HamacaWeb.CoreComponents
  alias HamacaWeb.RunStatus
  alias HamacaWeb.TimeAgo
  alias Phoenix.LiveView.JS
  # RE394 — a remote call for `button/1`'s pending face only; never `import` (see moduledoc).
  alias Schemas.Run

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

  defp elapsed_label(%{status: :running, started_at: at}, now), do: "elapsed #{clock(now, at)}"
  defp elapsed_label(%{status: :parked, started_at: at}, now), do: "parked #{clock(now, at)}"
  defp elapsed_label(%{status: :done, finished_at: at}, now), do: "finished #{TimeAgo.ago(now, at)}"
  defp elapsed_label(%{status: :failed, finished_at: at}, now), do: "stopped #{TimeAgo.ago(now, at)}"

  defp elapsed_label(%{status: :cancelled, finished_at: at}, now), do: "cancelled #{TimeAgo.ago(now, at)}"

  defp clock(_now, nil), do: ""
  defp clock(now, at), do: run_duration(max(DateTime.diff(now, at, :second), 0))

  defp times_label(1), do: "1 time"
  defp times_label(n), do: "#{n} times"

  # Run-list colors per status (RE426, card mockup "A — one list…"). `dot` / `pulse?` drive the
  # status chip's dot; `chip_bg` / `chip_c` color that chip; `entry_border` / `entry_bg` tint the
  # latest entry — role 35% / 4% over base-100, while `:cancelled` (no mockup state) keeps a
  # primary 20% / 5% wash. RE237: each tint/ink pair is re-expressed via the token mapping's
  # Rule B (brand hues) — N for the tints, P for the ink, against that status's role's
  # light-theme L.
  defp run_status_style(:running),
    do: %{
      entry_border: "color-mix(in oklab, var(--color-secondary) 35%, var(--color-base-100))",
      entry_bg: "color-mix(in oklab, var(--color-secondary) 4%, var(--color-base-100))",
      chip_c: "color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content))",
      dot: "var(--color-secondary)",
      pulse?: true,
      chip_bg: "color-mix(in oklab, var(--color-secondary) 10%, var(--color-base-100))"
    }

  defp run_status_style(:parked),
    do: %{
      entry_border: "color-mix(in oklab, var(--color-warning) 35%, var(--color-base-100))",
      entry_bg: "color-mix(in oklab, var(--color-warning) 4%, var(--color-base-100))",
      chip_c: "color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content))",
      dot: "var(--color-warning)",
      pulse?: false,
      chip_bg: "color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100))"
    }

  defp run_status_style(:failed),
    do: %{
      entry_border: "color-mix(in oklab, var(--color-error) 35%, var(--color-base-100))",
      entry_bg: "color-mix(in oklab, var(--color-error) 4%, var(--color-base-100))",
      chip_c: "color-mix(in oklab, var(--color-error) 70%, var(--color-base-content))",
      dot: "var(--color-error)",
      pulse?: false,
      chip_bg: "color-mix(in oklab, var(--color-error) 10%, var(--color-base-100))"
    }

  # The dot has long used the accent (teal) token while the surrounding tint/ink were
  # blue-ish (hue 250, primary's range) literals — a pre-existing choice, unrelated to
  # RE237. The faint tint backgrounds keep that blue wash via var(--color-primary), but the
  # chip ink was `oklch 0.44 0.06 250` — C 0.06 is a Rule-N near-neutral (see `delete_style/1`
  # in story_map_components.ex), and Rule B ran `primary` to 55% to reach L 0.44, landing at
  # C ~0.09 and reading as active Human-blue on a cancelled run. The ink goes neutral; the
  # wash stays.
  defp run_status_style(:cancelled),
    do: %{
      entry_border: "color-mix(in oklab, var(--color-primary) 20%, var(--color-base-100))",
      entry_bg: "color-mix(in oklab, var(--color-primary) 5%, var(--color-base-100))",
      chip_c: "color-mix(in oklab, var(--color-base-content) 70%, transparent)",
      dot: "var(--color-accent)",
      pulse?: false,
      chip_bg: "color-mix(in oklab, var(--color-primary) 10%, var(--color-base-100))"
    }

  defp run_status_style(:done),
    do: %{
      entry_border: "color-mix(in oklab, var(--color-success) 35%, var(--color-base-100))",
      entry_bg: "color-mix(in oklab, var(--color-success) 4%, var(--color-base-100))",
      chip_c: "color-mix(in oklab, var(--color-success) 45%, var(--color-base-content))",
      dot: "var(--color-success)",
      pulse?: false,
      chip_bg: "color-mix(in oklab, var(--color-success) 10%, var(--color-base-100))"
    }

  # ---------- run_list (RE426) ----------

  @doc """
  Every run of a card as one collapsible entry in a single `RUNS · N` list (card mockup
  "A — one list, latest run carries its own header"). `entries` is
  `[%{detail: %Hamaca.Runs.RunDetail{}, number: n}]`, newest first and never empty: the head is
  the latest run, open and tinted by its status, with `:latest_body` at the top of its body.
  `open` is ignored across patches so a run update never undoes the user's toggle.
  """
  attr :entries, :list, required: true
  attr :now, :any, default: nil
  attr :task_progress, :map, default: nil
  slot :latest_body

  def run_list(assigns) do
    now = assigns.now || DateTime.utc_now()

    entries =
      assigns.entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> Map.put(entry, :latest?, index == 0) end)

    assigns = assign(assigns, now: now, entries: entries, count: length(entries))

    ~H"""
    <div id="run-list" style="display:flex;flex-direction:column;gap:8px;">
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
        RUNS · {@count}
      </div>
      <details
        :for={entry <- @entries}
        id={"run-entry-#{entry.number}"}
        class="run-entry"
        open={entry.latest?}
        phx-mounted={JS.ignore_attributes(["open"])}
        style={"border-radius:10px;#{entry_tint(entry)}"}
      >
        <.run_entry_header entry={entry} now={@now} />
        <div
          class="pl-3 sm:pl-[30px]"
          style="padding-top:4px;padding-right:14px;padding-bottom:14px;display:flex;flex-direction:column;gap:14px;"
        >
          <%= if entry.latest? do %>
            {render_slot(@latest_body)}
            <.run_entry_stats
              :if={entry.detail.status in Run.terminal_statuses()}
              detail={entry.detail}
            />
            <.run_node_timeline detail={entry.detail} task_progress={@task_progress} />
          <% else %>
            <.run_entry_stats detail={entry.detail} />
            <.run_node_timeline detail={entry.detail} />
          <% end %>
        </div>
      </details>
    </div>
    """
  end

  defp entry_tint(%{latest?: true, detail: %{status: status}}) do
    styles = run_status_style(status)
    "border:1px solid #{styles.entry_border};background:#{styles.entry_bg};"
  end

  defp entry_tint(_entry), do: "border:1px solid var(--color-base-300);background:var(--color-base-100);"

  attr :entry, :map, required: true
  attr :now, :any, required: true

  defp run_entry_header(assigns) do
    detail = assigns.entry.detail

    assigns =
      assign(assigns,
        detail: detail,
        styles: run_status_style(detail.status),
        stage: stage_chip(detail),
        meta: entry_meta(assigns.entry, assigns.now)
      )

    ~H"""
    <summary style="display:flex;align-items:center;gap:8px;padding:10px 12px;cursor:pointer;list-style:none;flex-wrap:wrap;row-gap:6px;">
      <span
        class="run-entry-chev"
        style="color:color-mix(in oklab, var(--color-base-content) 55%, transparent);font-size:13px;width:12px;"
      >
        ▸
      </span>
      <span
        :if={@stage}
        class="run-entry-stage"
        style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.06em;text-transform:uppercase;border:1px solid var(--color-base-300);background:var(--color-base-200);color:color-mix(in oklab, var(--color-base-content) 85%, transparent);border-radius:5px;padding:2px 8px;flex:0 0 auto;"
      >
        {@stage}
      </span>
      <span
        class="run-entry-title"
        style="font-size:13px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"
      >
        Run #{@entry.number}
      </span>
      <span
        :if={@detail.flow_version}
        class="run-entry-version"
        style="font-family:var(--font-mono);font-size:10.5px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
      >
        v{@detail.flow_version}
      </span>
      <span
        class="run-entry-status"
        style={"font-family:var(--font-mono);font-size:9px;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;display:inline-flex;align-items:center;gap:5px;background:#{@styles.chip_bg};color:#{@styles.chip_c};border-radius:4px;padding:2px 7px;"}
      >
        <span style={"display:inline-block;width:6px;height:6px;border-radius:50%;background:#{@styles.dot};#{if @styles.pulse?, do: "animation:relaypulse 1.6s ease-in-out infinite;"}"} />
        {RunStatus.descriptor(@detail.status).label}
      </span>
      <span
        :if={@entry.latest?}
        class="run-entry-latest"
        style="font-family:var(--font-mono);font-size:9px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
      >
        LATEST
      </span>
      <span
        class="run-entry-meta"
        style="margin-left:auto;font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
      >
        {@meta}
      </span>
    </summary>
    """
  end

  # The one display fallback for a run's stage: the domain's work-stage name, else the flow key.
  defp stage_chip(%{stage_name: nil, flow_key: nil}), do: nil
  defp stage_chip(detail), do: String.upcase(detail.stage_name || detail.flow_key)

  defp entry_meta(%{latest?: true, detail: detail}, now) do
    finished? = detail.status in Run.terminal_statuses()

    join_meta([
      elapsed_label(detail, now),
      if(finished?, do: run_duration(detail.totals.duration_s)),
      meta_cost(detail.totals.cost)
    ])
  end

  defp entry_meta(%{detail: detail}, now) do
    join_meta([
      run_duration(detail.totals.duration_s),
      meta_cost(detail.totals.cost),
      TimeAgo.ago(now, detail.finished_at)
    ])
  end

  defp meta_cost(nil), do: nil
  defp meta_cost(cost), do: run_cost(cost)

  defp join_meta(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  attr :detail, :map, required: true

  defp run_entry_stats(assigns) do
    ~H"""
    <div class="run-entry-stats" style="display:flex;gap:18px;flex-wrap:wrap;">
      <.stat
        label="DURATION"
        value={run_duration(@detail.totals.duration_s)}
        value_c={history_duration_color(@detail.status)}
      />
      <.stat label="NODES" value={"#{@detail.totals.nodes}"} />
      <.stat label="ATTEMPTS" value={"#{@detail.totals.attempts}"} />
      <.stat label="COST" value={run_cost(@detail.totals.cost)} />
    </div>
    """
  end

  # ---------- run_mini_graph ----------

  attr :path, :list, required: true
  attr :run, :map, required: true
  attr :task_progress, :map, default: nil

  def run_mini_graph(assigns) do
    current_index = Enum.find_index(assigns.path, &(&1 == assigns.run.current_node))

    # A fan_out with an entry in `branch_bars` (RE440) draws its split segment — even once the run
    # has moved past it. Stories and tests pass plain maps, hence Map.get/3.
    branch_bars = Map.get(assigns.run, :branch_bars, %{})

    segments =
      assigns.path
      |> Enum.with_index()
      |> Enum.map(fn {node, index} -> {segment_state(index, current_index), Map.get(branch_bars, node, [])} end)

    assigns =
      assigns
      |> assign(:segments, segments)
      |> assign(:header, mini_graph_header(assigns.run, assigns.task_progress))

    ~H"""
    <div class="run-mini-graph">
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);margin-bottom:6px;">
        {@header}
      </div>
      <div style="display:flex;gap:3px;align-items:center;">
        <%= for {state, bars} <- @segments do %>
          <%= if bars != [] do %>
            <.branch_segment bars={bars} />
          <% else %>
            <span
              class={"run-mini-graph-segment run-mini-graph-segment-#{state}"}
              style={segment_style(state)}
            />
          <% end %>
        <% end %>
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
      "animation:relaypulse 1.6s ease-in-out infinite;box-shadow:0 0 0 2px color-mix(in oklab, var(--color-secondary) 25%, transparent);"
  end

  defp segment_style(:pending),
    do: "flex:1;height:9px;border-radius:3px;background:var(--color-field-border-hover);opacity:0.5;"

  # ---------- branch_segment (RE440) ----------

  @doc """
  A fan-out region's progress segment: one wider segment split into a thin bar per branch, in
  branch order. `bars` are `Hamaca.Runs.RunDetail.bar()`s; `size` picks the drawer mini graph's
  13px segment or the card face's 7px one.
  """
  attr :bars, :list, required: true
  attr :size, :atom, values: [:drawer, :face], default: :drawer

  def branch_segment(assigns) do
    ~H"""
    <span class="run-branch-segment" style={branch_segment_style(@size)}>
      <span
        :for={bar <- @bars}
        class={"run-branch-bar run-branch-bar-#{bar}"}
        style={branch_bar_shape(@size) <> branch_bar_style(bar)}
      />
    </span>
    """
  end

  defp branch_segment_style(:drawer), do: "flex:1.6;height:13px;display:flex;flex-direction:column;gap:2px;"
  defp branch_segment_style(:face), do: "flex:1.6;height:7px;display:flex;flex-direction:column;gap:1px;"

  defp branch_bar_shape(:drawer), do: "flex:1;border-radius:2px;"
  defp branch_bar_shape(:face), do: "flex:1;border-radius:1px;"

  # One clause per RunDetail.bar_states/0 member — no catch-all, so a new state fails loudly.
  defp branch_bar_style(:succeeded), do: "background:var(--color-success);"
  defp branch_bar_style(:running), do: "background:var(--color-secondary);animation:relaypulse 1.6s ease-in-out infinite;"
  defp branch_bar_style(:failed), do: "background:var(--color-error);"
  defp branch_bar_style(:queued), do: "background:color-mix(in oklab, var(--color-secondary) 25%, var(--color-base-100));"
  defp branch_bar_style(:parked), do: "background:var(--color-warning);"
  defp branch_bar_style(:cancelled), do: "background:var(--color-field-border-hover);opacity:0.5;"

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
            <.loop_chip row={row} />
          <% :pending -> %>
            <div
              class="run-timeline-row run-timeline-row-pending"
              style="display:flex;align-items:center;gap:10px;padding:8px 10px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
            >
              <span style="display:inline-block;width:14px;height:14px;border-radius:50%;border:2px solid var(--color-field-border-hover);flex:0 0 auto;" />
              <span style="font-family:var(--font-mono);font-size:12px;">
                {Enum.join(row.nodes, " → ")}
              </span>
            </div>
          <% :region -> %>
            <.run_region_group row={row} task_progress={@task_progress} />
          <% :node -> %>
            <.timeline_node_row row={row} task_progress={@task_progress} wrap?={join_row?(row)} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # A region's `fan_in` and the row that gets its results wrap like the lane rows (RE440).
  defp join_row?(row), do: row.type == :fan_in or not is_nil(row[:join]) or not is_nil(row[:joined_from])

  attr :row, :map, required: true

  defp loop_chip(assigns) do
    ~H"""
    <div
      class="run-loop-chip"
      style="font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));background:color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100));border-radius:6px;padding:6px 10px;"
    >
      ↺ {loop_text(@row)}
    </div>
    """
  end

  defp loop_text(%{from_node: f, to_node: t, attempt: a, max_loops: nil}), do: "#{f} failed → #{t} · attempt #{a}"

  defp loop_text(%{from_node: f, to_node: t, attempt: a, max_loops: m}),
    do: "#{f} failed → #{t} · attempt #{a} · max #{m}"

  # RE440 chip copy, from the domain's numbers only (`tally`, `max_parallel`, `join`, `joined_from`).
  defp region_chip(%{open?: true, tally: tally} = row), do: {open_region_text(row) <> parked_text(tally), :running}

  defp region_chip(%{tally: %{failed: failed, total: total}}) when failed > 0,
    do: {"#{failed} of #{total} failed", :failed}

  defp region_chip(%{tally: %{succeeded: total, total: total}}) when total > 0,
    do: {"#{total} of #{total} succeeded", :succeeded}

  defp region_chip(_row), do: {"cancelled", :neutral}

  defp open_region_text(%{tally: %{queued: queued} = tally, max_parallel: max}) when queued > 0,
    do: "#{tally.running} running · #{queued} queued" <> if(max, do: " · max #{max}", else: "")

  defp open_region_text(%{tally: tally}), do: "#{tally.running} of #{tally.total} running"

  defp parked_text(%{parked: parked}) when parked > 0, do: " · #{parked} parked"
  defp parked_text(_tally), do: ""

  defp join_chip(%{state: :waiting, join: %{total: total}}), do: {"waits for all #{total}", :neutral}

  defp join_chip(%{state: :failed, join: %{total: total, failed: failed}}),
    do: {"failed · #{failed} of #{total} branches failed", :failed}

  defp join_chip(_row), do: nil

  defp joined_from_text(count), do: "gets all #{count} results, labelled"

  @chip_box "font-family:var(--font-mono);font-size:9.5px;border-radius:4px;padding:2px 6px;white-space:nowrap;"

  defp chip_style(:running),
    do:
      @chip_box <>
        "color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));background:color-mix(in oklab, var(--color-secondary) 8%, var(--color-base-100));"

  defp chip_style(:failed),
    do:
      @chip_box <>
        "color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));background:color-mix(in oklab, var(--color-error) 8%, var(--color-base-100));"

  defp chip_style(:succeeded),
    do:
      @chip_box <>
        "color:color-mix(in oklab, var(--color-success) 45%, var(--color-base-content));background:color-mix(in oklab, var(--color-success) 10%, var(--color-base-100));"

  defp chip_style(:neutral),
    do:
      @chip_box <>
        "color:color-mix(in oklab, var(--color-base-content) 65%, transparent);background:color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100));"

  # ---------- run_region_group (RE440) ----------

  @doc """
  One fan-out region entry of the run timeline (RE440, card mockup "Run view — branches grouped
  under the fan-out"): the `fan_out` header row with the region's summary chip, duration and
  cost, then a teal rail holding one labelled lane per branch, in branch-position order. `row`
  is one `kind: :region` row of `Hamaca.Runs.RunDetail`'s timeline; ids are keyed on its
  `fan_out_execution_id`, unique across every run the drawer lists.
  """
  attr :row, :map, required: true
  attr :task_progress, :map, default: nil

  def run_region_group(assigns) do
    row = assigns.row
    {chip_text, chip_tone} = region_chip(row)

    assigns =
      assign(assigns,
        id: "run-region-#{row.fan_out_execution_id}",
        header: Map.merge(row.header, %{duration_s: row.duration_s, cost: row.cost}),
        chip_text: chip_text,
        chip_tone: chip_tone
      )

    ~H"""
    <div id={@id} class="run-region" style="display:flex;flex-direction:column;gap:8px;">
      <.timeline_node_row row={@header} task_progress={@task_progress} wrap?>
        <:chip>
          <span id={"#{@id}-chip"} class="run-region-chip" style={chip_style(@chip_tone)}>
            {@chip_text}
          </span>
        </:chip>
      </.timeline_node_row>
      <div
        class="run-region-rail"
        style="margin-left:8px;padding-left:18px;border-left:2px solid color-mix(in oklab, var(--color-accent) 40%, var(--color-base-100));display:flex;flex-direction:column;gap:12px;"
      >
        <div
          :for={lane <- @row.lanes}
          id={"#{@id}-lane-#{lane.branch}"}
          class="run-region-lane"
          style="display:flex;flex-direction:column;gap:5px;"
        >
          <div
            class="run-region-lane-label"
            style="font-family:var(--font-mono);font-size:9px;font-weight:700;letter-spacing:0.06em;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
          >
            BRANCH · {lane.branch}
          </div>
          <%= for {lane_row, index} <- Enum.with_index(lane.rows) do %>
            <%= case lane_row.kind do %>
              <% :loop -> %>
                <.loop_chip row={lane_row} />
              <% :node -> %>
                <.timeline_node_row
                  row={lane_row}
                  task_progress={@task_progress}
                  wrap?
                  succeeded?={
                    index == last_node_index(lane) and RunDetail.branch_bar(lane) == :succeeded
                  }
                />
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp last_node_index(lane) do
    lane.rows
    |> Enum.with_index()
    |> Enum.filter(fn {row, _index} -> row.kind == :node end)
    |> List.last({nil, nil})
    |> elem(1)
  end

  # `wrap?` (RE440): a row inside a region, or a region's `fan_in` / joined-from row, wraps its
  # chips onto a second line instead of truncating the node name. Every other row keeps the
  # truncating single line (RE426).
  attr :row, :map, required: true
  attr :task_progress, :map, default: nil
  attr :wrap?, :boolean, default: false
  attr :succeeded?, :boolean, default: false, doc: "the last row of a lane whose branch succeeded"
  slot :chip, doc: "an extra chip after the row's own (the region header's summary chip)"

  defp timeline_node_row(assigns) do
    assigns = assign(assigns, :join_chip, join_chip(assigns.row))

    ~H"""
    <div class="run-timeline-row" style="display:flex;flex-direction:column;gap:4px;">
      <div class="run-timeline-row-line" style={row_line_style(@wrap?)}>
        <.timeline_icon state={@row.state} type={@row.type} />
        <span class="run-timeline-name" style={row_name_style(@wrap?, @row.state)}>
          {@row.node_key}
        </span>
        <span :if={@row.type} class={type_tag_class(@row.type)} style={type_tag_style(@row.type)}>
          {@row.type}
        </span>
        {render_slot(@chip)}
        <span
          :if={@row.attempt > 1}
          class="run-attempt-chip"
          style="font-family:var(--font-mono);font-size:9.5px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);background:color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100));border-radius:4px;padding:2px 6px;white-space:nowrap;"
        >
          attempt {@row.attempt}
        </span>
        <span
          :if={@row.resumed?}
          class="run-resumed-chip"
          style="font-family:var(--font-mono);font-size:9.5px;color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));background:color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100));border-radius:4px;padding:2px 6px;"
        >
          session resumed
        </span>
        <span
          :if={@row.steered?}
          class="run-steered-chip"
          style="font-family:var(--font-mono);font-size:9.5px;color:color-mix(in oklab, var(--color-primary) 65%, var(--color-base-content));background:color-mix(in oklab, var(--color-primary) 5%, var(--color-base-100));border-radius:4px;padding:2px 6px;white-space:nowrap;"
        >
          steered
        </span>
        <span
          :if={@row.partial?}
          style="font-family:var(--font-mono);font-size:9.5px;color:color-mix(in oklab, var(--color-success) 45%, var(--color-base-content));"
        >
          partial
        </span>
        <span :if={@row.state == :queued} class="run-queued-chip" style={chip_style(:neutral)}>
          queued · waits for a free slot
        </span>
        <span :if={@join_chip} class="run-join-chip" style={chip_style(elem(@join_chip, 1))}>
          {elem(@join_chip, 0)}
        </span>
        <span :if={@row[:joined_from]} class="run-joined-from-chip" style={chip_style(:neutral)}>
          {joined_from_text(@row[:joined_from])}
        </span>
        <span :if={@succeeded?} class="run-lane-outcome" style={chip_style(:succeeded)}>
          succeeded
        </span>
        <%= unless placeholder_state?(@row.state) do %>
          <span style="margin-left:auto;font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);white-space:nowrap;">
            {run_duration(@row.duration_s)}
          </span>
          <span style="font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-success) 70%, var(--color-base-content));">
            {run_cost(@row.cost)}
          </span>
        <% end %>
      </div>
      <div
        :if={@row.state == :active && @task_progress}
        style="height:5px;border-radius:3px;background:color-mix(in oklab, var(--color-secondary) 20%, var(--color-base-100));overflow:hidden;"
      >
        <div style={"height:100%;background:var(--color-secondary);width:#{task_progress_pct(@task_progress)}%;"} />
      </div>
      <div
        :if={@row.state == :failed}
        style="background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border-radius:8px;padding:8px 10px;"
      >
        <div style="font-family:var(--font-mono);font-size:9px;font-weight:700;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));margin-bottom:4px;">
          OUTCOME: FAILED
        </div>
        <pre style="background:var(--color-neutral);color:color-mix(in oklab, var(--color-neutral-content) 95%, transparent);font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;border-radius:6px;padding:8px 10px;margin:0;"><%= @row.detail %></pre>
      </div>
    </div>
    """
  end

  defp row_line_style(false), do: "display:flex;align-items:center;gap:10px;min-width:0;"
  defp row_line_style(true), do: "display:flex;align-items:center;gap:6px 10px;flex-wrap:wrap;min-width:0;"

  defp row_name_style(false, _state),
    do:
      "font-family:var(--font-mono);font-size:13.5px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"

  defp row_name_style(true, state) do
    ink = if placeholder_state?(state), do: 65, else: 95

    "font-family:var(--font-mono);font-size:13.5px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) #{ink}%, transparent);white-space:nowrap;"
  end

  # A queued branch's placeholder and an open region's waiting `fan_in` (RE440): no execution
  # backs them, so their name is muted and they show no duration or cost.
  defp placeholder_state?(:queued), do: true
  defp placeholder_state?(:waiting), do: true
  defp placeholder_state?(_state), do: false

  attr :state, :atom, required: true
  attr :type, :atom, default: nil

  # RE440: a region's `fan_out` header always draws the fork — it labels the group.
  defp timeline_icon(%{type: :fan_out} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon run-timeline-icon-fan-out"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;color:color-mix(in oklab, var(--color-accent) 45%, var(--color-base-content));flex:0 0 auto;"
    >
      <svg
        width="13"
        height="13"
        viewBox="0 0 14 14"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linecap="round"
      >
        <path d="M7 1v5M7 6L2.5 12M7 6v6M7 6l4.5 6" />
      </svg>
    </span>
    """
  end

  # RE440: a branch held back by `max_parallel` — a dashed violet ring, never the grey pending ring.
  defp timeline_icon(%{state: :queued} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon run-timeline-icon-queued"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;flex:0 0 auto;box-sizing:border-box;border:2px dashed color-mix(in oklab, var(--color-secondary) 45%, var(--color-base-100));"
    />
    """
  end

  # RE440: an open region's `fan_in`, waiting on every branch — the join glyph in muted ink.
  defp timeline_icon(%{state: :waiting} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon run-timeline-icon-waiting"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);flex:0 0 auto;"
    >
      <svg
        width="13"
        height="13"
        viewBox="0 0 14 14"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linecap="round"
      >
        <path d="M2.5 2L7 8M7 2v6M11.5 2L7 8M7 8v5" />
      </svg>
    </span>
    """
  end

  defp timeline_icon(%{state: :done} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-success);color:var(--color-success-content);font-size:11px;flex:0 0 auto;"
    >
      ✓
    </span>
    """
  end

  defp timeline_icon(%{state: :failed} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-error);color:var(--color-error-content);font-size:11px;flex:0 0 auto;"
    >
      ✕
    </span>
    """
  end

  defp timeline_icon(%{state: :cancelled} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-field-border);color:color-mix(in oklab, var(--color-base-content) 65%, transparent);font-size:11px;flex:0 0 auto;"
    >
      ⊘
    </span>
    """
  end

  defp timeline_icon(%{state: :stopped} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:5px;background:var(--color-error);color:var(--color-error-content);font-size:11px;flex:0 0 auto;"
    >
      ⊗
    </span>
    """
  end

  # RE358: a human's Steer now stopped this attempt — a human action, so primary (blue).
  defp timeline_icon(%{state: :steered} = assigns) do
    ~H"""
    <span
      class="run-timeline-icon"
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-primary);color:var(--color-primary-content);font-size:11px;flex:0 0 auto;"
    >
      ↪
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
      style="display:flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-warning);color:var(--color-warning-content);font-size:11px;flex:0 0 auto;animation:relaypulse 1.6s ease-in-out infinite;"
    >
      ?
    </span>
    """
  end

  defp type_tag_class(:agent), do: "run-type-tag run-type-tag-agent hidden sm:inline"
  defp type_tag_class(:gate), do: "run-type-tag run-type-tag-gate hidden sm:inline"
  defp type_tag_class(:fan_out), do: "run-type-tag run-type-tag-fan_out hidden sm:inline"
  defp type_tag_class(:fan_in), do: "run-type-tag run-type-tag-fan_in hidden sm:inline"
  defp type_tag_class(_type), do: "run-type-tag run-type-tag-shell hidden sm:inline"

  defp type_tag_style(:agent),
    do:
      "font-family:var(--font-mono);font-size:8px;font-weight:700;text-transform:uppercase;" <>
        "background:color-mix(in oklab, var(--color-secondary) 10%, var(--color-base-100));color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));border-radius:3px;padding:2px 5px;"

  defp type_tag_style(:gate),
    do:
      "font-family:var(--font-mono);font-size:8px;font-weight:700;text-transform:uppercase;" <>
        "background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));border-radius:3px;padding:2px 5px;"

  defp type_tag_style(:fan_out), do: control_tag_style()
  defp type_tag_style(:fan_in), do: control_tag_style()

  defp type_tag_style(_type),
    do:
      "font-family:var(--font-mono);font-size:8px;font-weight:700;text-transform:uppercase;" <>
        "background:color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100));color:color-mix(in oklab, var(--color-base-content) 70%, transparent);border-radius:3px;padding:2px 5px;"

  # RE440: the control nodes' accent (teal) tag, in the agent tag's 8px/700/uppercase mono box.
  defp control_tag_style,
    do:
      "font-family:var(--font-mono);font-size:8px;font-weight:700;text-transform:uppercase;" <>
        "background:color-mix(in oklab, var(--color-accent) 15%, var(--color-base-100));color:color-mix(in oklab, var(--color-accent) 45%, var(--color-base-content));border-radius:3px;padding:2px 5px;"

  defp task_progress_pct(%{done: done, total: total}) when total > 0, do: min(100, round(done / total * 100))
  defp task_progress_pct(_task_progress), do: 0

  # ---------- run_state_banner ----------

  # RE279: no :parked variant — a parked run's answer surface lives once, on the drawer's Detail
  # tab, and the blocked strip above the tabs carries the blocked state.
  attr :variant, :atom, required: true, values: [:reentry, :revoked, :circuit, :failed, :rate_limited]
  attr :detail, :map, default: nil
  attr :rate_limited, :map, default: nil, doc: "RE320 %{resumes_at} for the :rate_limited variant"
  attr :card, :any, default: nil
  attr :claimer, :string, default: nil

  attr :advance_available?, :boolean,
    default: false,
    doc:
      "RE310: `Hamaca.Runs.advance_foreach_available?/1`, computed in the LiveView. The component must NEVER re-derive this rule — one rule, one place."

  def run_state_banner(%{variant: :reentry} = assigns) do
    rejection = assigns.card.rejection
    assigns = assign(assigns, :rejection, rejection)

    ~H"""
    <div
      class="run-banner run-banner-reentry"
      style="border-left:3px solid var(--color-primary);background:color-mix(in oklab, var(--color-primary) 5%, var(--color-base-100));border-radius:8px;padding:14px 16px;"
    >
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-primary) 55%, var(--color-base-content));margin-bottom:8px;">
        RE-ENTRY · CHANGES REQUESTED BY {String.upcase(@rejection.rejected_by)}
      </div>
      <blockquote style="margin:0 0 8px 0;padding:8px 10px;background:color-mix(in oklab, var(--color-base-100) 60%, transparent);border-radius:6px;font-size:13px;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);">
        {@rejection.note}
      </blockquote>
      <div style="font-size:12px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
        rejected from {@rejection.from_stage_name} {TimeAgo.ago(
          DateTime.utc_now(),
          @rejection.rejected_at
        )}
      </div>
      <%!-- `oklch 0.50 0.04 250` is slate, not Human-blue: a Rule-N near-neutral (see
      `delete_style/1` in story_map_components.ex). Rule B needed `primary` at 70% to reach L 0.50,
      which lands at C 0.10 and reads as a blue statement this hint line never made. --%>
      <div style="font-size:12px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);margin-top:4px;">
        the run reads this note before implement
      </div>
    </div>
    """
  end

  def run_state_banner(%{variant: :revoked} = assigns) do
    ~H"""
    <div class="run-banner run-banner-revoked" style="display:flex;flex-direction:column;gap:10px;">
      <div style="display:flex;align-items:center;gap:8px;font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);">
        <span style="width:8px;height:8px;border-radius:50%;background:var(--color-secondary);" />
        FLOW
        <span style="color:color-mix(in oklab, var(--color-base-content) 45%, transparent);">→</span>
        <span style="display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--color-primary);color:var(--color-primary-content);font-size:9px;">
          {initials(@claimer)}
        </span>
        {@claimer}
      </div>
      <div style="background:color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100));border-radius:8px;padding:12px 14px;">
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);margin-bottom:6px;">
          CLAIMED BY A HUMAN
        </div>
        <p style="font-size:13px;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);margin:0;">
          A human claimed this card while {Hamaca.Brand.agent_name()} was working, so the run at
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
      class="run-banner run-banner-circuit action-group"
      style="border-left:3px solid var(--color-error);background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border-radius:8px;padding:14px 16px;"
    >
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));margin-bottom:6px;">
        ⊗ CIRCUIT BREAKER TRIPPED
      </div>
      <p style="font-size:13px;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);margin:0 0 8px 0;">
        <strong>{@tripped}</strong> returned failed {times_label(@repeats)}
      </p>
      <pre style="background:var(--color-neutral);color:color-mix(in oklab, var(--color-neutral-content) 95%, transparent);font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;border-radius:6px;padding:8px 10px;margin:0 0 10px 0;"><%= @detail_text %></pre>
      <.failure_stats totals={@totals} />
      <.retry_button />
      <.advance_button available?={@advance_available?} />
    </div>
    """
  end

  # The honest banner for every failure mode that ISN'T a tripped breaker. Same red
  # frame, no invented cause: it leads with `runs.failure_detail` — the engine's
  # human-first sentence, which the Run tab surfaced nowhere before RLY-179.
  # RE320 — a live run whose queued job waits on a roster paused at its usage limits. The
  # sentence is `Hamaca.Runs.rate_limited_run_detail/1`, the same copy `relay why` prints; the
  # warning tokens match the run face's "Rate limited" chip (no artboard covers rate limiting).
  def run_state_banner(%{variant: :rate_limited} = assigns) do
    ~H"""
    <div
      id="run-banner-rate-limited"
      class="run-banner run-banner-rate-limited"
      style="border-left:3px solid var(--color-warning);background:color-mix(in oklab, var(--color-warning) 8%, var(--color-base-100));border-radius:8px;padding:14px 16px;"
    >
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content));margin-bottom:6px;">
        ⏸ RATE LIMITED
      </div>
      <p style="font-size:13px;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);margin:0;">
        {Runs.rate_limited_run_detail(@rate_limited.resumes_at)}
      </p>
    </div>
    """
  end

  def run_state_banner(%{variant: :failed} = assigns) do
    assigns =
      assigns
      |> assign(:reason, assigns.detail.failure_reason)
      |> assign(:detail_text, assigns.detail.last_failure_detail)
      |> assign(:totals, assigns.detail.totals)

    ~H"""
    <div
      class="run-banner run-banner-failed action-group"
      style="border-left:3px solid var(--color-error);background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border-radius:8px;padding:14px 16px;"
    >
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));margin-bottom:6px;">
        ⊗ RUN FAILED
      </div>
      <p style="font-size:13px;color:color-mix(in oklab, var(--color-base-content) 90%, transparent);margin:0 0 8px 0;">
        {@reason}
      </p>
      <pre
        :if={@detail_text}
        style="background:var(--color-neutral);color:color-mix(in oklab, var(--color-neutral-content) 95%, transparent);font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;border-radius:6px;padding:8px 10px;margin:0 0 10px 0;"
      ><%= @detail_text %></pre>
      <.failure_stats :if={@totals} totals={@totals} />
      <.retry_button />
      <.advance_button available?={@advance_available?} />
    </div>
    """
  end

  # RLY-189 — the minimal Retry control on a terminally failed run's banner.
  #
  # Deliberately not designed: RLY-178 owns the human surface for run failure and
  # recovery. This ships the smallest usable affordance so the feature is usable
  # the day it merges. There is no `--at` picker — the CLI covers that case.
  #
  # The `:circuit` and `:failed` variants are mutually exclusive (`Hamaca.Runs.breaker_tripped?/1`
  # gates them), so the shared `run-retry` DOM id is never duplicated on a page.
  defp retry_button(assigns) do
    ~H"""
    <CoreComponents.button
      id="run-retry"
      type="button"
      class="btn btn-sm btn-primary"
      phx-click="retry_run"
      style="margin-top:10px;"
      pending="Retrying…"
    >
      Retry
    </CoreComponents.button>
    """
  end

  @doc """
  RE310 — the human hatch out of the already-committed deadlock: check the bound foreach task
  off and continue with the next one. A secondary action beside the primary Retry (`btn-ghost`
  vs `btn-primary`), and it renders ONLY when `Hamaca.Runs.advance_foreach_available?/1` holds,
  so it is never a button that can only refuse.

  Deliberately not designed: `docs/designs/Relay Card Run Panel.dc.html` shows a retry
  affordance on a parked run and no "task already done" control, so there is nothing to match
  and this borrows `retry_button/1`'s shape instead. The places that render it — the `:circuit`
  and `:failed` banners, and (for a parked run, RE279) `CoreComponents.needs_input_panel/1` — are
  mutually exclusive on a page, because both banners require a run that is not parked, so the
  shared `run-advance` DOM id is never duplicated.
  """
  attr :available?, :boolean, required: true

  def advance_button(assigns) do
    ~H"""
    <CoreComponents.button
      :if={@available?}
      id="run-advance"
      type="button"
      class="btn btn-sm btn-ghost"
      phx-click="advance_run"
      style="margin-top:10px;margin-left:8px;"
      pending="Continuing…"
    >
      Task already done — continue
    </CoreComponents.button>
    """
  end

  # ---------- stopped_work_banner ----------

  @doc ~S"""
  `Hamaca.Runs.stopped_work/2`'s board-level verdict as one line. ONE copy of the
  reason→severity mapping — `:runner_outdated` and `:runner_rate_limited` are the warning tint
  (the machines are there and beating, they are just refused or paused at their usage
  limit), every other reason is the error tint (nothing is going to pick the work up at all) —
  so the board and the Runners view can never drift.

  The copy is `verdict.detail`, which is already a complete sentence; never re-derive it. The
  caller owns layout margins via `class` and the DOM `id`, since the same verdict renders on two
  pages under two different ids.

  Deliberately no `<.icon>`: this module imports no CoreComponents (see the moduledoc), and
  `icon/1` is only ever `<span class={[@name, @class]} />`.
  """
  attr :id, :string, required: true
  attr :verdict, :map, required: true
  attr :class, :any, default: nil

  def stopped_work_banner(assigns) do
    ~H"""
    <div
      id={@id}
      class={["flex items-center gap-3 rounded-lg px-4 py-2.5 text-sm", @class]}
      style={stopped_work_style(@verdict.reason)}
    >
      <span class="hero-exclamation-triangle size-4" />
      <span class="flex-1">{@verdict.detail}</span>
    </div>
    """
  end

  defp stopped_work_style(:runner_outdated),
    do:
      "background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 50%, var(--color-base-100));color:color-mix(in oklab, var(--color-warning) 35%, var(--color-base-content));"

  defp stopped_work_style(:runner_rate_limited), do: stopped_work_style(:runner_outdated)

  defp stopped_work_style(_reason),
    do:
      "background:color-mix(in oklab, var(--color-error) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 30%, var(--color-base-100));color:color-mix(in oklab, var(--color-error) 60%, var(--color-base-content));"

  # ---------- rate_limit_note ----------

  @doc ~S"""
  A runner's usage pause as one amber line (RE320, per harness since RE436): `codex 5h 95% / 90% ·
  resumes 3:40 PM UTC`, or `claude-code refused (5h) · resumes …`. Takes the plain map
  `Hamaca.Runs.active_rate_limit/2` returns; the copy is `Hamaca.Runs.rate_limit_phrase/1` and
  `Hamaca.Runs.resume_time_label/1`, never re-derived here. No artboard covers rate limiting, so it
  borrows the stalled run face's warning tokens.
  """
  attr :id, :string, required: true
  attr :rate_limit, :map, required: true

  def rate_limit_note(assigns) do
    ~H"""
    <span
      id={@id}
      class="run-rate-limit-note font-mono"
      style="font-size:11.5px;color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));"
    >
      {Runs.rate_limit_phrase(@rate_limit)} · resumes {Runs.resume_time_label(@rate_limit.resets_at)}
    </span>
    """
  end

  # ---------- pre_rename_hint ----------

  @relay_update_command "./relay update"

  @doc ~S"""
  The Runners page's calm nudge for a runner still installed as `./relay` during the relay →
  hamaca compatibility window (RE486): a base-200 strip under the panel header with the restart
  note and a copyable `./relay update`. The page renders it when the roster entry's `pre_rename`
  (`Hamaca.Runs.pre_rename_runner?/1`) is true — never re-derived here. Deliberately neutral —
  no warning/error tokens and never the word OUTDATED: the runner keeps working. The copy control
  is the shared `CoreComponents.copy_button/1` (the card mockup draws a text "Copy" button).
  """
  attr :id, :string, required: true

  def pre_rename_hint(assigns) do
    assigns = assign(assigns, :command, @relay_update_command)

    ~H"""
    <div
      id={@id}
      class="flex flex-wrap items-center gap-x-3 gap-y-2 px-[18px] py-2.5 bg-base-200 border-b border-base-300"
      style="font-size:12.5px;"
    >
      <span style="font-size:13px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);">
        ↑
      </span>
      <span
        class="flex-1 min-w-[220px]"
        style="color:color-mix(in oklab, var(--color-base-content) 75%, transparent);"
      >
        Still installed as <code class="font-mono">./relay</code>. It keeps working. To switch it to <code class="font-mono">./hamaca</code>, run this in its checkout and then restart the runner:
      </span>
      <span class="flex items-center gap-2 rounded-lg bg-base-100 border border-base-300 pl-2.5 pr-1 py-1">
        <code class="font-mono" style="font-size:12px;">{@command}</code>
        <CoreComponents.copy_button id={"#{@id}-copy"} text={@command} label="Copy update command" />
      </span>
    </div>
    """
  end

  # ---------- runner rows (RE337) ----------

  @doc """
  The runners page's row frame — the artboard's WORKING NOW job row (`Relay Runners.dc.html`
  lines ~98-115). Shared so the HELD WORKTREES rows reuse the idiom rather than inventing one.
  """
  def runner_row_style do
    "display:flex;align-items:center;gap:10px;border:1px solid var(--color-base-300);" <>
      "background:var(--color-base-200);border-radius:8px;padding:8px 11px;"
  end

  @doc ~S"""
  The DOM id of a held-worktree row — `held-<runner>-<ref>`, CSS-safe (a runner name like
  `mac.local` has a dot). The ONE builder: the row and the starvation banner's anchor links both
  call it, so a link can never point at an id the row does not carry.
  """
  def held_row_id(runner_name, ref), do: "held-" <> dom_safe(runner_name) <> "-" <> dom_safe(ref)

  defp dom_safe(value), do: String.replace(to_string(value), ~r/[^A-Za-z0-9_-]/, "-")

  # ---------- held_worktree_row ----------

  @doc """
  One per-card worktree a runner holds (RE337), for the runners page's HELD WORKTREES section:
  state badge, card ref (linking to the card) and title, the run's status and how long it has
  sat, and the two actions. Every decision is precomputed by `Hamaca.Runs.list_runner_status/2`
  — `holding.release` (`Hamaca.Runs.release_action/1`) and `holding.cancellable`
  (`Hamaca.Runs.cancellable_holding?/1`) — this component only renders them. No artboard covers
  this section; it wears the WORKING NOW row frame (`runner_row_style/0`).
  """
  attr :id, :string, required: true
  attr :runner, :string, required: true, doc: "the runner's name (phx-value-runner)"
  attr :holding, :map, required: true
  attr :href, :string, required: true, doc: "the card link"

  def held_worktree_row(assigns) do
    assigns = assign(assigns, :disabled_reason, disabled_reason(assigns.holding.release))

    ~H"""
    <div
      id={@id}
      class="held-worktree-row"
      style={
        runner_row_style() <>
          "flex-wrap:wrap;row-gap:6px;" <>
          if(@holding.release == :hidden, do: "opacity:0.6;", else: "")
      }
    >
      <%!-- Two wrap groups, so a narrow runner column drops the status + actions onto their own
           line instead of squeezing the title to 0px and pushing the buttons out of the frame. --%>
      <div
        class="held-worktree-identity"
        style="display:flex;align-items:center;gap:10px;flex:1 1 220px;min-width:0;"
      >
        <span
          class={["badge badge-sm font-mono font-bold", holding_badge_class(@holding.release)]}
          style="font-size:9.5px;letter-spacing:0.06em;flex-shrink:0;"
        >
          {@holding.state}
        </span>
        <.link
          navigate={@href}
          class="font-mono"
          style="font-size:12px;font-weight:600;flex-shrink:0;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"
        >
          {@holding.ref}
        </.link>
        <span style="font-size:12px;color:color-mix(in oklab, var(--color-base-content) 75%, transparent);flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
          {@holding.title || "—"}
        </span>
      </div>
      <div
        class="held-worktree-actions"
        style="display:flex;align-items:center;justify-content:flex-end;flex-wrap:wrap;gap:8px;margin-left:auto;max-width:100%;"
      >
        <span
          id={"#{@id}-status"}
          class="font-mono"
          style="font-size:11px;white-space:nowrap;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
        >
          {holding_status_label(@holding)}
        </span>
        <span
          :if={@holding.release == :releasing}
          id={"#{@id}-releasing"}
          class="badge badge-sm badge-ghost font-mono"
        >
          releasing…
        </span>
        <button
          :if={@holding.release == :enabled}
          id={"#{@id}-release"}
          type="button"
          class="btn btn-xs"
          phx-click="release_worktree"
          phx-value-runner={@runner}
          phx-value-ref={@holding.ref}
          data-confirm={release_confirm(@holding.ref, @runner)}
        >
          Release worktree
        </button>
        <span :if={@disabled_reason} class="tooltip tooltip-left" data-tip={@disabled_reason}>
          <button id={"#{@id}-release"} type="button" class="btn btn-xs" disabled>
            Release worktree
          </button>
        </span>
        <button
          :if={@holding.cancellable}
          id={"#{@id}-cancel"}
          type="button"
          class="btn btn-xs btn-outline btn-error"
          phx-click="cancel_held_run"
          phx-value-ref={@holding.ref}
          data-confirm={"Cancel #{@holding.ref}'s run? It ends now and its worktree is released on the runner's next heartbeat."}
        >
          Cancel run
        </button>
      </div>
    </div>
    """
  end

  defp disabled_reason({:disabled, reason}), do: reason
  defp disabled_reason(_release), do: nil

  # Amber is Blocked in this palette: an idle holding is a slot waiting on a human — the leak,
  # legible at a glance. Everything else is neutral. Keyed on the precomputed release action,
  # never on a state string (magic-value rule).
  defp holding_badge_class(release) when release in [:enabled, :releasing], do: "badge-warning"
  defp holding_badge_class(_release), do: "badge-ghost"

  defp release_confirm(ref, runner) do
    "Release #{ref}'s worktree on runner #{runner}? The run stays parked and rebuilds its " <>
      "worktree from its branch when it resumes. Uncommitted edits are stashed (auto-salvage) " <>
      "and will not be restored."
  end

  defp holding_status_label(%{release: :hidden}), do: "retained (failed run, no slot)"
  defp holding_status_label(%{run: nil}), do: "no active run"

  defp holding_status_label(%{run: run, held_s: held_s}) do
    [Atom.to_string(run.status), reason_label(run.parked_reason), short_age(held_s)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp reason_label(nil), do: nil
  defp reason_label(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp short_age(nil), do: nil
  defp short_age(s) when s < 60, do: "<1m"
  defp short_age(s) when s < 3600, do: "#{div(s, 60)}m"
  defp short_age(s) when s < 86_400, do: "#{div(s, 3600)}h"
  defp short_age(s), do: "#{div(s, 86_400)}d"

  # ---------- starvation_banner ----------

  @doc """
  The runners page's starvation alert (RE337): exclusive work is queued past the awaiting-slot
  grace and every exclusive slot is held by an idle (parked) card. Takes the verdict from
  `Hamaca.Runs.starvation/2` and lists each holder, linking to its HELD WORKTREES row
  (`held_row_id/2`). Amber — the same warning tokens as the full capacity chip and the
  outdated-runner `stopped_work_banner/1`.
  """
  attr :id, :string, required: true
  attr :verdict, :map, required: true

  def starvation_banner(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-col gap-1.5 rounded-lg px-4 py-2.5 text-sm"
      style={stopped_work_style(:runner_outdated)}
    >
      <div class="flex items-center gap-3">
        <span class="hero-exclamation-triangle size-4" />
        <span class="flex-1">
          Exclusive work is starved: {jobs_waiting(length(@verdict.waiting))}, and every exclusive slot is held by a parked card.
        </span>
      </div>
      <div class="flex flex-wrap gap-x-4 gap-y-1 pl-7">
        <a
          :for={holder <- @verdict.holders}
          id={"#{@id}-holder-#{holder.ref}"}
          href={"#" <> held_row_id(holder.runner, holder.ref)}
          class="font-mono text-xs underline"
        >
          {holder.ref}{if holder.title, do: " #{holder.title}"} · {holder.runner}{if holder.held_s,
            do: " · #{short_age(holder.held_s)}"}
        </a>
      </div>
    </div>
    """
  end

  defp jobs_waiting(1), do: "1 job waiting"
  defp jobs_waiting(n), do: "#{n} jobs waiting"

  attr :totals, :map, required: true

  defp failure_stats(assigns) do
    ~H"""
    <div style="display:flex;gap:18px;">
      <.stat
        label="ATTEMPTS"
        value={"#{@totals.attempts} · stopped"}
        value_c="color-mix(in oklab, var(--color-error) 70%, var(--color-base-content))"
      />
      <.stat label="DURATION" value={run_duration(@totals.duration_s)} />
      <.stat label="SPENT" value={run_cost(@totals.cost)} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :value_c, :string, default: "color-mix(in oklab, var(--color-base-content) 95%, transparent)"

  defp stat(assigns) do
    ~H"""
    <div>
      <div style="font-family:var(--font-mono);font-size:9px;font-weight:600;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);">
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

  defp history_duration_color(:failed), do: "color-mix(in oklab, var(--color-error) 70%, var(--color-base-content))"
  defp history_duration_color(_status), do: "color-mix(in oklab, var(--color-base-content) 95%, transparent)"

  @doc ~S"""
  The short rate-limited label (RE320): `Rate limited · resumes 3:40 PM UTC`. Takes
  `Hamaca.Runs.roster_rate_limit/2`'s `%{resumes_at}`; ONE copy for the run face chip and the
  card drawer's Activity chip.
  """
  def rate_limited_label(%{resumes_at: resumes_at}), do: "Rate limited · resumes #{Runs.resume_time_label(resumes_at)}"

  # ---------- run_face (board card) ----------

  attr :run, :any, required: true
  attr :ref, :string, required: true
  attr :progress_at, :any, default: nil
  attr :stalled?, :boolean, default: false

  attr :rate_limited, :map,
    default: nil,
    doc: "RE320 %{resumes_at} when this run's queued job waits on a roster paused at its usage limit"

  def run_face(assigns) do
    # A reported pause is the more specific fact than an inferred stall — never show both.
    assigns =
      assigns
      |> assign(:state, face_state(assigns.run))
      |> assign(:stalled?, assigns.stalled? and is_nil(assigns.rate_limited))

    ~H"""
    <div
      id={"card-#{@ref}-run-face"}
      class="run-face"
      data-run-state={@state}
      data-stalled={to_string(@stalled?)}
      data-rate-limited={to_string(@rate_limited != nil)}
    >
      <.face_running
        :if={@state == :running}
        summary={run_summary(@run)}
        ref={@ref}
        progress_at={@progress_at}
        stalled?={@stalled?}
        rate_limited={@rate_limited}
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
  attr :rate_limited, :map, default: nil

  defp face_running(assigns) do
    # RE320: rate limited wears the stalled treatment's amber tokens (no artboard covers it), but
    # it is a REPORTED state, so it shows without the stall threshold.
    # RE440: `branches` is set only while a fan-out region is open (face tests and stories pass
    # summaries without the key); the fan_out — still `current_node` — draws the split segment.
    assigns =
      assigns
      |> assign(:amber?, assigns.stalled? or assigns.rate_limited != nil)
      |> assign(:branches, Map.get(assigns.summary, :branches))

    ~H"""
    <div
      class={[
        "run-face-running",
        @stalled? && "run-face-stalled",
        @rate_limited && "run-face-rate-limited"
      ]}
      style={
        "display:flex;flex-direction:column;gap:6px;" <>
          if(@amber?,
            do:
              "background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 40%, var(--color-base-100));border-radius:8px;padding:8px 10px;",
            else: ""
          )
      }
    >
      <div class="run-face-segments" style="display:flex;gap:2px;align-items:center;">
        <%= for i <- 1..(@summary.node_count || 1) do %>
          <%= if @branches && i == @summary.node_index do %>
            <.branch_segment bars={@branches.bars} size={:face} />
          <% else %>
            <span style={"flex:1;height:5px;border-radius:2px;#{face_segment_style(i, @summary)}"} />
          <% end %>
        <% end %>
      </div>
      <div style={"display:flex;align-items:center;gap:6px;font-family:var(--font-mono);font-size:11px;color:#{if(@amber?, do: "color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content))", else: "color-mix(in oklab, var(--color-secondary) 60%, var(--color-base-content))")};"}>
        <%!-- RE440: the dot, ring and age keep their size; the node position and the branch
             count are ONE text run that wraps inside the remaining width. --%>
        <span
          class="run-face-dot"
          style={"flex-shrink:0;width:6px;height:6px;border-radius:50%;background:#{if(@amber?, do: "var(--color-warning)", else: "var(--color-secondary)")};#{unless @amber?, do: "animation:relaypulse 1.6s ease-in-out infinite;"}"}
        />
        <span
          :if={not @amber?}
          class="run-face-ring"
          style="flex-shrink:0;display:flex;align-items:center;justify-content:center;width:22px;height:22px;border-radius:50%;background:var(--color-secondary);animation:relayring 1.6s ease-out infinite;"
        />
        <span class="run-face-node" style="flex:1;min-width:0;">
          node {@summary.node_index} of {@summary.node_count}<span
            :if={@branches}
            class="run-face-branches"
          > {face_branches_label(@branches)}</span>
        </span>
        <span
          :if={@progress_at}
          id={"card-#{@ref}-run-age"}
          class="run-face-age"
          style="flex-shrink:0;white-space:nowrap;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
        >
          {TimeAgo.ago(DateTime.utc_now(), @progress_at)}
        </span>
      </div>
      <div
        :if={@stalled?}
        class="run-face-stalled-note"
        style="font-family:var(--font-mono);font-size:10.5px;color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));"
      >
        Quiet for a while — may be stuck
      </div>
      <div
        :if={@rate_limited}
        id={"card-#{@ref}-rate-limited"}
        class="run-face-rate-limited-note"
        style="font-family:var(--font-mono);font-size:10.5px;color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));"
      >
        {rate_limited_label(@rate_limited)}
      </div>
    </div>
    """
  end

  defp face_branches_label(%{ended: ended, total: total, queued: queued}) do
    count = "· #{ended}/#{total} branches"
    if queued > 0, do: "#{count} · #{queued} queued", else: count
  end

  defp face_segment_style(i, %{node_index: idx}) when is_integer(idx) and i < idx,
    do: "background:var(--color-secondary);"

  defp face_segment_style(i, %{node_index: idx}) when is_integer(idx) and i == idx,
    do: "background:var(--color-secondary);animation:relaypulse 1.6s ease-in-out infinite;"

  defp face_segment_style(_i, _summary),
    do: "background:color-mix(in oklab, var(--color-secondary) 25%, var(--color-base-100));"

  attr :summary, :map, required: true

  defp face_parked(assigns) do
    ~H"""
    <div
      class="run-face-badge run-face-parked"
      style="display:flex;align-items:center;gap:8px;background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));border-radius:8px;padding:8px 10px;"
    >
      <span style="display:flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:50%;background:var(--color-warning);color:var(--color-warning-content);font-size:9px;animation:relaypulse 1.6s ease-in-out infinite;">
        ?
      </span>
      <div>
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content));">
          {String.upcase(RunStatus.descriptor(:parked).label)} · NEEDS YOU
        </div>
        <div style="font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));">
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
      style="display:flex;align-items:center;gap:8px;background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border-radius:8px;padding:8px 10px;"
    >
      <span style={"display:flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:50%;background:var(#{RunStatus.descriptor(:failed).token});color:var(#{RunStatus.descriptor(:failed).token}-content);font-size:10px;"}>
        {RunStatus.descriptor(:failed).icon}
      </span>
      <div>
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));">
          {String.upcase(RunStatus.descriptor(:failed).label)}
          <%= if @circuit? do %>
            · CIRCUIT BREAKER
          <% end %>
        </div>
        <div style="font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-error) 65%, var(--color-base-content));">
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
      style="display:flex;flex-direction:column;gap:2px;background:color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100));border-radius:8px;padding:8px 10px;"
    >
      <div style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));">
        QUEUED · {String.upcase(@flow.key)} FLOW
      </div>
      <%!-- `oklch 0.55 0.06 292` is a violet-tinted grey, not violet ink: a Rule-N near-neutral
      (see `delete_style/1` in story_map_components.ex). Rule B needed `secondary` at 95% to reach
      L 0.55, which lands at C 0.15 — the QUEUED label above carries the AI signal, not this. --%>
      <div style="font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);">
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
      <span style="font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-success) 45%, var(--color-base-content));">
        {RunStatus.descriptor(:done).icon} {RunStatus.descriptor(:done).label} · {run_duration(
          @summary[:duration_s]
        )}
      </span>
      <span style="font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-success) 70%, var(--color-base-content));">
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
      style="display:flex;align-items:center;gap:8px;background:var(--color-field-hover);border-radius:8px;padding:8px 10px;"
    >
      <span style="display:flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:50%;background:color-mix(in oklab, var(--color-base-content) 40%, var(--color-base-100));color:var(--color-neutral-content);font-size:10px;">
        ⊘
      </span>
      <div>
        <div style="font-family:var(--font-mono);font-size:10px;font-weight:700;letter-spacing:0.05em;color:color-mix(in oklab, var(--color-base-content) 75%, transparent);">
          {String.upcase(RunStatus.descriptor(:cancelled).label)}
        </div>
        <div style="font-family:var(--font-mono);font-size:11px;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);">
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
      style="display:flex;align-items:center;gap:6px;background:color-mix(in oklab, var(--color-primary) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-primary) 30%, var(--color-base-100));border-radius:6px;padding:6px 8px;"
    >
      <span style="width:15px;height:15px;border-radius:50%;background:var(--color-primary);color:var(--color-primary-content);display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:700;flex:0 0 auto;">
        ✓
      </span>
      <span style="font-size:10.5px;font-weight:600;letter-spacing:0.03em;color:color-mix(in oklab, var(--color-primary) 55%, var(--color-base-content));font-family:var(--font-mono);">
        READY FOR YOUR REVIEW
      </span>
    </div>
    """
  end
end
