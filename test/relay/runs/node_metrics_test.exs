defmodule Relay.Runs.NodeMetricsTest do
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Schemas.NodeExecution

  # Persist a completed run on `board` for `flow_key`, `n` seconds ago, with the given status.
  defp completed_run(board, flow_key, ago_s, status) do
    card = insert(:card, board: board, stage: insert(:stage, board: board))
    started = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -ago_s, :second)

    insert(:run,
      card: card,
      flow_key: flow_key,
      status: status,
      started_at: started,
      finished_at: DateTime.add(started, 600, :second)
    )
  end

  defp exec(run, node, opts \\ []) do
    insert(:node_execution,
      run: run,
      node: node,
      visit: Keyword.get(opts, :visit, 1),
      attempt: Keyword.get(opts, :attempt, 1),
      outcome: Keyword.get(opts, :outcome, :succeeded),
      duration_s: Keyword.get(opts, :duration_s, 60),
      cost: Keyword.get(opts, :cost)
    )
  end

  defp flow_with_nodes(board, keys) do
    insert(:flow,
      board: board,
      key: "code",
      nodes: Enum.map(keys, &%Schemas.Flow.Node{key: &1, type: :agent, model: "sonnet"})
    )
  end

  describe "node_metrics_for_flow/2" do
    test "one row per node with executions, in flow node order, with counts and percentiles" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["branch", "implement", "smoke"])
      run = completed_run(board, "code", 60, :done)

      # branch: 1 exec, 30s
      exec(run, "branch", duration_s: 30)
      # implement: 3 execs across 2 visits (visit 2 = a loop lap), durations 60/120/90
      exec(run, "implement", visit: 1, attempt: 1, duration_s: 60)
      exec(run, "implement", visit: 1, attempt: 2, duration_s: 120, outcome: :failed)
      exec(run, "implement", visit: 2, attempt: 1, duration_s: 90)
      # smoke: no executions -> omitted

      [branch, implement] = Runs.node_metrics_for_flow(flow, window: "all")

      # flow node order preserved; smoke omitted (zero execs)
      assert branch.node_key == "branch"
      assert implement.node_key == "implement"

      assert branch.runs == 1
      assert branch.duration_p50 == 30

      assert implement.runs == 3
      assert implement.duration_p50 == 90
      # 3 execs across 2 visits -> mean attempts/visit = 1.5
      assert implement.attempts_mean == 1.5
      # visit 2 is one lap beyond the first
      assert implement.loop_laps == 1
      # verdict counts fold from NodeExecution.outcomes/0
      assert implement.verdict_split ==
               %{succeeded: 2, failed: 1, partial: 0, needs_input: 0}
    end

    test "cost is nil when unset and a rounded Decimal when a subset carry cost" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["implement"])
      run = completed_run(board, "code", 60, :done)

      exec(run, "implement", cost: nil)
      assert [%{cost_p50: nil, cost_p95: nil}] = Runs.node_metrics_for_flow(flow, window: "all")

      exec(run, "implement", cost: Decimal.new("0.50"))
      exec(run, "implement", cost: Decimal.new("1.50"))
      [row] = Runs.node_metrics_for_flow(flow, window: "all")
      # percentile_cont(0.5) over [0.50, 1.50] linearly interpolates to the midpoint, 1.00
      # (nearest-rank percentiles would pick 0.50 — that's not what percentile_cont computes).
      assert Decimal.equal?(row.cost_p50, Decimal.new("1.00"))
    end

    test "window filtering excludes out-of-window executions" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["implement"])
      old = completed_run(board, "code", 40 * 86_400, :done)
      recent = completed_run(board, "code", 1 * 86_400, :done)
      exec(recent, "implement", duration_s: 10)
      # backdate the old execution's started_at outside the 7d window
      old_exec = exec(old, "implement", duration_s: 10)
      old_started = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -40 * 86_400, :second)
      Relay.Repo.update!(Ecto.Changeset.change(old_exec, started_at: old_started))

      assert [%{runs: 1}] = Runs.node_metrics_for_flow(flow, window: "7d")
      assert [%{runs: 2}] = Runs.node_metrics_for_flow(flow, window: "all")
    end
  end

  describe "flow_metrics_summary/2" do
    test "totals, completed %, median end-to-end; total_spend nil with no cost" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["implement"])
      done = completed_run(board, "code", 60, :done)
      _failed = completed_run(board, "code", 60, :failed)
      exec(done, "implement")

      summary = Runs.flow_metrics_summary(flow, window: "all")
      assert summary.total_runs == 2
      assert summary.completed == 1
      assert summary.completed_pct == 50
      assert summary.total_spend == nil
      assert summary.median_end_to_end == 600
    end
  end

  describe "policy accessors" do
    test "windows and threshold are defined once" do
      assert Runs.metric_windows() == ["7d", "30d", "all"]
      assert Runs.default_window() == "30d"
      assert Runs.min_runs_for_percentiles() == 10
      assert Runs.default_window() in Runs.metric_windows()
    end
  end

  test "outcome closed set is sourced from the schema, not retyped" do
    # guards against a drifting literal in verdict_split
    assert :partial in NodeExecution.outcomes()
  end
end
