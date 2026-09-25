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

  # A completed run of `flow_key` for an EXISTING card — card scoping needs two runs to share
  # one card, which `completed_run/4` (which mints its own card) cannot express.
  defp completed_run_for(card, flow_key, ago_s, elapsed_s) do
    started = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -ago_s, :second)

    insert(:run,
      card: card,
      flow_key: flow_key,
      status: :done,
      started_at: started,
      finished_at: DateTime.add(started, elapsed_s, :second)
    )
  end

  # Push a persisted execution back in time by `ago_s`, preserving its original elapsed
  # duration (finished_at - started_at) — the factory stamps both timestamps near "now", so
  # shifting only started_at would balloon the computed duration instead of just relocating it.
  defp backdate(exec, ago_s) do
    started = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -ago_s, :second)
    elapsed = DateTime.diff(exec.finished_at, exec.started_at, :second)
    finished = DateTime.add(started, elapsed, :second)
    Relay.Repo.update!(Ecto.Changeset.change(exec, started_at: started, finished_at: finished))
  end

  # An execution at explicit offsets (seconds) from `t0` — gap tests need exact timestamps, and a
  # shared `t0` keeps every row on one clock (utc_now per row could tick a second between rows).
  # `finish_s: nil` leaves finished_at nil (an abandoned / in-flight execution).
  defp exec_at(run, node, t0, start_s, finish_s, opts \\ []) do
    insert(:node_execution,
      run: run,
      node: node,
      visit: Keyword.get(opts, :visit, 1),
      outcome: Keyword.get(opts, :outcome, :succeeded),
      resume_at: Keyword.get(opts, :resume_at),
      started_at: DateTime.add(t0, start_s, :second),
      finished_at: finish_s && DateTime.add(t0, finish_s, :second)
    )
  end

  defp t0_ago(ago_s), do: DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -ago_s, :second)

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
               %{succeeded: 2, failed: 1, partial: 0, needs_input: 0, blocked: 0}
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

  describe "card scoping (RE235)" do
    test "sums every run of the flow for one card and excludes other cards" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["implement"])
      stage = insert(:stage, board: board)
      mine = insert(:card, board: board, stage: stage)
      other = insert(:card, board: board, stage: stage)

      # decision 4: two runs of the same flow for the same card — BOTH count
      run_a = completed_run_for(mine, "code", 120, 600)
      run_b = completed_run_for(mine, "code", 60, 300)
      exec(run_a, "implement", duration_s: 30, cost: Decimal.new("0.50"))
      exec(run_b, "implement", duration_s: 90, cost: Decimal.new("1.00"))

      # another card's execution on the same node must not leak in
      other_run = completed_run_for(other, "code", 60, 600)
      exec(other_run, "implement", duration_s: 1000, cost: Decimal.new("9.00"))

      [row] = Runs.node_metrics_for_flow(flow, window: "all", card_id: mine.id)

      assert row.runs == 2
      assert row.duration_total == 120
      assert Decimal.equal?(row.cost_total, Decimal.new("1.50"))
      assert row.verdict_split == %{succeeded: 2, failed: 0, partial: 0, needs_input: 0, blocked: 0}

      summary = Runs.flow_metrics_summary(flow, window: "all", card_id: mine.id)

      assert summary.total_runs == 2
      assert summary.completed == 2
      assert summary.total_end_to_end == 900
      assert Decimal.equal?(summary.total_spend, Decimal.new("1.50"))
    end

    test "card scope ignores the window — every execution of that card counts (decision 3)" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["implement"])
      card = insert(:card, board: board, stage: insert(:stage, board: board))

      old_run = completed_run_for(card, "code", 40 * 86_400, 600)
      recent_run = completed_run_for(card, "code", 86_400, 300)
      old_run |> exec("implement", duration_s: 10) |> backdate(40 * 86_400)
      exec(recent_run, "implement", duration_s: 20)

      # the same "7d" window that drops the old row in flow scope...
      assert [%{runs: 1}] = Runs.node_metrics_for_flow(flow, window: "7d")
      # ...is not applied at all in card scope
      assert [%{runs: 2, duration_total: 30}] =
               Runs.node_metrics_for_flow(flow, window: "7d", card_id: card.id)

      assert %{total_runs: 2, total_end_to_end: 900} =
               Runs.flow_metrics_summary(flow, window: "7d", card_id: card.id)
    end

    test "totals are computed in flow scope too, and card_id: nil is exactly the unscoped query" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["implement"])
      run = completed_run(board, "code", 60, :done)
      exec(run, "implement", duration_s: 30, cost: Decimal.new("0.50"))
      exec(run, "implement", duration_s: 90, cost: Decimal.new("1.00"))

      [row] = Runs.node_metrics_for_flow(flow, window: "all")
      assert row.duration_total == 120
      assert Decimal.equal?(row.cost_total, Decimal.new("1.50"))
      assert Runs.flow_metrics_summary(flow, window: "all").total_end_to_end == 600

      assert Runs.node_metrics_for_flow(flow, window: "all", card_id: nil) ==
               Runs.node_metrics_for_flow(flow, window: "all")

      assert Runs.flow_metrics_summary(flow, window: "all", card_id: nil) ==
               Runs.flow_metrics_summary(flow, window: "all")
    end

    test "a card with no executions of this flow yields no rows and a zeroed summary" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["implement"])
      quiet = insert(:card, board: board, stage: insert(:stage, board: board))
      exec(completed_run(board, "code", 60, :done), "implement")

      assert Runs.node_metrics_for_flow(flow, window: "all", card_id: quiet.id) == []

      assert %{total_runs: 0, completed: 0, completed_pct: 0, total_end_to_end: nil} =
               Runs.flow_metrics_summary(flow, window: "all", card_id: quiet.id)
    end
  end

  describe "node_waits_for_flow/2 (RE345)" do
    test "a hand-off gap is charged to the node it precedes; a run's first node gets none" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["branch", "implement"])
      run = completed_run(board, "code", 3600, :done)
      t0 = t0_ago(3600)

      exec_at(run, "branch", t0, 0, 30)
      exec_at(run, "implement", t0, 90, 200)

      waits = Runs.node_waits_for_flow(flow, window: "all")

      refute Map.has_key?(waits, "branch")

      assert waits["implement"] == %{
               wait_p50: 60,
               wait_p95: 60,
               wait_total: 60,
               wait_count: 1,
               held_p50: nil,
               held_p95: nil,
               held_total: nil,
               held_count: 0
             }
    end

    test "a gap after a :needs_input execution is held, not wait" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["review", "fix"])
      run = completed_run(board, "code", 7200, :done)
      t0 = t0_ago(7200)

      exec_at(run, "review", t0, 0, 60, outcome: :needs_input)
      exec_at(run, "fix", t0, 3660, 3700)

      assert %{
               held_total: 3600,
               held_count: 1,
               held_p50: 3600,
               wait_count: 0,
               wait_total: nil,
               wait_p50: nil
             } = Runs.node_waits_for_flow(flow, window: "all")["fix"]
    end

    test "a gap after a :blocked execution (usage limit with resume_at) is held" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["implement"])
      run = completed_run(board, "code", 7200, :done)
      t0 = t0_ago(7200)

      exec_at(run, "implement", t0, 0, 10, outcome: :blocked, resume_at: DateTime.add(t0, 600, :second))
      exec_at(run, "implement", t0, 610, 700)

      assert %{held_total: 600, held_count: 1, wait_count: 0} =
               Runs.node_waits_for_flow(flow, window: "all")["implement"]
    end

    test "the held classification is exactly holding_outcomes/0" do
      board = insert(:board)
      keys = Enum.map(NodeExecution.outcomes(), &Atom.to_string/1)
      flow = flow_with_nodes(board, Enum.map(keys, &("after_" <> &1)))
      t0 = t0_ago(7200)

      for outcome <- NodeExecution.outcomes() do
        run = completed_run(board, "code", 7200, :done)
        exec_at(run, "first", t0, 0, 10, outcome: outcome)
        exec_at(run, "after_#{outcome}", t0, 40, 50)
      end

      waits = Runs.node_waits_for_flow(flow, window: "all")

      for outcome <- NodeExecution.outcomes() do
        row = waits["after_#{outcome}"]

        if outcome in NodeExecution.holding_outcomes() do
          assert %{held_count: 1, held_total: 30, wait_count: 0} = row
        else
          assert %{wait_count: 1, wait_total: 30, held_count: 0} = row
        end
      end
    end

    test "in a loop A→B→A the gap before the second A is charged to A" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["implement", "review"])
      run = completed_run(board, "code", 3600, :done)
      t0 = t0_ago(3600)

      exec_at(run, "implement", t0, 0, 10)
      exec_at(run, "review", t0, 20, 30, outcome: :failed)
      exec_at(run, "implement", t0, 50, 60, visit: 2)

      waits = Runs.node_waits_for_flow(flow, window: "all")
      assert %{wait_total: 10, wait_count: 1} = waits["review"]
      assert %{wait_total: 20, wait_count: 1} = waits["implement"]
    end

    test "no gap is recorded after an execution with no finished_at, nor for a negative gap" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["a", "b", "c"])
      run = completed_run(board, "code", 3600, :done)
      t0 = t0_ago(3600)

      exec_at(run, "a", t0, 0, nil, outcome: nil)
      exec_at(run, "b", t0, 100, 500)
      # c starts before b finished (clock skew) — defensive skip
      exec_at(run, "c", t0, 200, 300)

      assert Runs.node_waits_for_flow(flow, window: "all") == %{}
    end

    test "the window applies to the successor: a predecessor before `since` still yields its gap" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["plan", "implement"])
      run = completed_run(board, "code", 9 * 86_400, :done)
      t0 = t0_ago(8 * 86_400)

      # plan: started 8 days ago (outside 7d); implement: started 6 days ago (inside 7d)
      exec_at(run, "plan", t0, 0, 60)
      exec_at(run, "implement", t0, 2 * 86_400, 2 * 86_400 + 60)

      waits = Runs.node_waits_for_flow(flow, window: "7d")
      assert %{wait_total: 172_740, wait_count: 1} = waits["implement"]
      refute Map.has_key?(waits, "plan")
    end

    test "window excludes a gap whose successor started before `since`" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["plan", "implement"])
      run = completed_run(board, "code", 41 * 86_400, :done)
      t0 = t0_ago(40 * 86_400)

      exec_at(run, "plan", t0, 0, 60)
      exec_at(run, "implement", t0, 120, 180)

      assert Runs.node_waits_for_flow(flow, window: "7d") == %{}
      assert %{wait_total: 60} = Runs.node_waits_for_flow(flow, window: "all")["implement"]
    end

    test "card scope counts only that card's runs and ignores the window" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["plan", "implement"])
      stage = insert(:stage, board: board)
      mine = insert(:card, board: board, stage: stage)
      other = insert(:card, board: board, stage: stage)

      old_t0 = t0_ago(40 * 86_400)
      old_run = completed_run_for(mine, "code", 40 * 86_400, 600)
      exec_at(old_run, "plan", old_t0, 0, 10)
      exec_at(old_run, "implement", old_t0, 30, 40)

      t0 = t0_ago(3600)
      new_run = completed_run_for(mine, "code", 3600, 600)
      exec_at(new_run, "plan", t0, 0, 10)
      exec_at(new_run, "implement", t0, 50, 60)

      other_run = completed_run_for(other, "code", 3600, 600)
      exec_at(other_run, "plan", t0, 0, 10)
      exec_at(other_run, "implement", t0, 1010, 1020)

      assert %{wait_total: 60, wait_count: 2} =
               Runs.node_waits_for_flow(flow, window: "7d", card_id: mine.id)["implement"]

      # flow scope, same window: the 40-day-old gap drops out, the other card's comes in
      assert %{wait_total: 1040, wait_count: 2} =
               Runs.node_waits_for_flow(flow, window: "7d")["implement"]
    end

    test "other flows and other boards are excluded" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["plan", "implement"])
      t0 = t0_ago(3600)

      mine = completed_run(board, "code", 3600, :done)
      exec_at(mine, "plan", t0, 0, 10)
      exec_at(mine, "implement", t0, 20, 30)

      other_flow_run = completed_run(board, "spec", 3600, :done)
      exec_at(other_flow_run, "plan", t0, 0, 10)
      exec_at(other_flow_run, "implement", t0, 500, 510)

      other_board = insert(:board)
      other_board_run = completed_run(other_board, "code", 3600, :done)
      exec_at(other_board_run, "plan", t0, 0, 10)
      exec_at(other_board_run, "implement", t0, 900, 910)

      assert %{"implement" => %{wait_total: 10, wait_count: 1}} =
               Runs.node_waits_for_flow(flow, window: "all")
    end

    test "p50/p95 are percentile_cont over each class separately" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["plan", "implement"])
      t0 = t0_ago(7200)

      for gap <- [10, 20, 30] do
        run = completed_run(board, "code", 7200, :done)
        exec_at(run, "plan", t0, 0, 10)
        exec_at(run, "implement", t0, 10 + gap, 100 + gap)
      end

      held_run = completed_run(board, "code", 7200, :done)
      exec_at(held_run, "plan", t0, 0, 10, outcome: :needs_input)
      exec_at(held_run, "implement", t0, 1010, 1100)

      row = Runs.node_waits_for_flow(flow, window: "all")["implement"]
      # percentile_cont(0.95) over [10, 20, 30] = 20 + 0.9 * 10 = 29
      assert %{wait_p50: 20, wait_p95: 29, wait_total: 60, wait_count: 3} = row
      assert %{held_p50: 1000, held_p95: 1000, held_total: 1000, held_count: 1} = row
    end

    test "node_metrics_for_flow/2 rows carry the wait keys, nil/0 for a node with no gaps" do
      board = insert(:board)
      flow = flow_with_nodes(board, ["branch", "implement"])
      run = completed_run(board, "code", 3600, :done)
      t0 = t0_ago(3600)

      exec_at(run, "branch", t0, 0, 30)
      exec_at(run, "implement", t0, 90, 200)

      [branch, implement] = Runs.node_metrics_for_flow(flow, window: "all")

      assert %{
               wait_p50: nil,
               wait_p95: nil,
               wait_total: nil,
               wait_count: 0,
               held_p50: nil,
               held_p95: nil,
               held_total: nil,
               held_count: 0
             } = branch

      assert %{runs: 1, wait_total: 60, wait_count: 1, held_count: 0} = implement
    end
  end

  describe "policy accessors" do
    test "windows and threshold are defined once" do
      assert Runs.metric_windows() == ["7d", "30d", "all"]
      assert Runs.default_window() == "30d"
      assert Runs.min_runs_for_percentiles() == 10
      assert Runs.default_window() in Runs.metric_windows()
    end

    test "the scope closed set and the card_id -> scope mapping are defined once (RE235)" do
      assert Runs.metric_scopes() == [:flow, :card]
      assert Runs.metric_scope(nil) == :flow
      assert Runs.metric_scope(42) == :card
      assert Runs.metric_scope(nil) in Runs.metric_scopes()
      assert Runs.metric_scope(42) in Runs.metric_scopes()
    end
  end

  test "outcome closed set is sourced from the schema, not retyped" do
    # guards against a drifting literal in verdict_split
    assert :partial in NodeExecution.outcomes()
  end

  test "holding_outcomes/0 is a subset of outcomes/0 (RE345)" do
    holding = NodeExecution.holding_outcomes()
    refute Enum.empty?(holding)
    assert holding -- NodeExecution.outcomes() == []
  end
end
