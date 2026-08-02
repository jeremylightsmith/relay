defmodule Relay.Runs.AuditTest do
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.Runs.Audit

  # The flow every fixture audits. `spec_review --failed--> implement` is the loop-back C1
  # reasons about; `smoke`'s only failed edge ends at the `done` sentinel, which is a run that
  # STOPPED, not a loop that dropped findings.
  alias Schemas.Flow.Edge

  defp audit_flow(board) do
    insert(:flow,
      board: board,
      key: "code",
      nodes: [
        %Schemas.Flow.Node{key: "implement", type: :agent},
        %Schemas.Flow.Node{key: "spec_review", type: :agent},
        %Schemas.Flow.Node{key: "smoke", type: :agent}
      ],
      edges: [
        %Edge{from: "start", to: "implement"},
        %Edge{from: "implement", to: "spec_review", on: :succeeded},
        %Edge{from: "spec_review", to: "implement", on: :failed},
        %Edge{from: "smoke", to: "done", on: :failed}
      ]
    )
  end

  defp run_for(board, opts \\ []) do
    card = insert(:card, board: board, stage: insert(:stage, board: board))
    now = DateTime.truncate(DateTime.utc_now(), :second)
    started_at = Keyword.get(opts, :started_at, DateTime.add(now, -60))

    insert(:run, card: card, flow_key: "code", status: :done, started_at: started_at)
  end

  defp exec(run, node, opts) do
    insert(:node_execution,
      run: run,
      node: node,
      visit: Keyword.get(opts, :visit, 1),
      attempt: Keyword.get(opts, :attempt, 1),
      outcome: Keyword.get(opts, :outcome, :succeeded),
      sub_task_id: Keyword.get(opts, :sub_task_id),
      git_sha: Keyword.get(opts, :git_sha)
    )
  end

  # node_executions.sub_task_id is a real foreign key to sub_tasks (nilify_all on delete), so a
  # fixture that means "some foreach iteration" must be a persisted row, not a bare literal.
  defp sub_task(run), do: insert(:sub_task, card: %Schemas.Card{id: run.card_id}).id

  # findings/2 is pure over preloaded runs, so load them exactly as the context does.
  defp findings(flow), do: Audit.findings(flow, Runs.recent_runs_for_flow(flow, window: "all"))

  describe "findings_dropped (C1)" do
    test "errors when the loop-back target's next execution carried a different sub_task" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      sub41 = sub_task(run)
      sub42 = sub_task(run)
      exec(run, "implement", sub_task_id: sub41)
      exec(run, "spec_review", outcome: :failed, sub_task_id: sub41)
      exec(run, "implement", sub_task_id: sub42)

      assert [finding] = findings(flow)
      assert finding.severity == :error
      assert finding.check == :findings_dropped
      assert finding.flow_key == "code"
      assert finding.node_key == "spec_review"
      assert finding.run_id == run.id
      assert finding.summary =~ "failed on sub_task #{sub41}"
      assert finding.summary =~ "carried sub_task #{sub42}"
      assert finding.fix =~ "re-open"
    end

    test "is silent when the loop-back target re-ran the same sub_task" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      sub = sub_task(run)
      exec(run, "spec_review", outcome: :failed, sub_task_id: sub)
      exec(run, "implement", sub_task_id: sub)

      assert findings(flow) == []
    end

    test "is silent when the loop-back target never ran again" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      exec(run, "spec_review", outcome: :failed, sub_task_id: sub_task(run))

      assert findings(flow) == []
    end

    test "is silent outside a foreach, where sub_task_id is nil" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      exec(run, "spec_review", outcome: :failed, sub_task_id: nil)
      exec(run, "implement", sub_task_id: sub_task(run))

      assert findings(flow) == []
    end

    test "is silent when the failed edge ends the run instead of looping back" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      exec(run, "smoke", outcome: :failed, sub_task_id: sub_task(run))
      exec(run, "implement", sub_task_id: sub_task(run))

      assert findings(flow) == []
    end
  end

  describe "verdict_flipped (C2)" do
    test "warns when a retry flipped failed -> succeeded at the same commit" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      sha = "9f3a1c2ddddddddddddddddddddddddddddddddd"
      exec(run, "smoke", visit: 2, attempt: 1, outcome: :failed, git_sha: sha)
      exec(run, "smoke", visit: 2, attempt: 2, outcome: :succeeded, git_sha: sha)

      assert [finding] = findings(flow)
      assert finding.severity == :warning
      assert finding.check == :verdict_flipped
      assert finding.node_key == "smoke"
      assert finding.summary =~ "flipped failed → succeeded"
      assert finding.summary =~ "9f3a1c2"
      assert finding.summary =~ "visit 2"
    end

    test "is silent when the commit changed between attempts" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      exec(run, "smoke", attempt: 1, outcome: :failed, git_sha: String.duplicate("a", 40))
      exec(run, "smoke", attempt: 2, outcome: :succeeded, git_sha: String.duplicate("b", 40))

      assert findings(flow) == []
    end

    test "is silent when either attempt has no git_sha" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      exec(run, "smoke", attempt: 1, outcome: :failed, git_sha: nil)
      exec(run, "smoke", attempt: 2, outcome: :succeeded, git_sha: nil)

      assert findings(flow) == []
    end

    test "escalates every flip in a run to error once two distinct nodes flipped" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      sha = String.duplicate("c", 40)
      exec(run, "smoke", attempt: 1, outcome: :failed, git_sha: sha)
      exec(run, "smoke", attempt: 2, outcome: :succeeded, git_sha: sha)
      exec(run, "implement", attempt: 1, outcome: :failed, git_sha: sha)
      exec(run, "implement", attempt: 2, outcome: :succeeded, git_sha: sha)

      assert [a, b] = findings(flow)
      assert a.severity == :error
      assert b.severity == :error
    end
  end

  describe "findings/2" do
    test "sorts errors before warnings and only emits known severities and checks" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      sha = String.duplicate("d", 40)
      exec(run, "smoke", attempt: 1, outcome: :failed, git_sha: sha)
      exec(run, "smoke", attempt: 2, outcome: :succeeded, git_sha: sha)
      exec(run, "spec_review", outcome: :failed, sub_task_id: sub_task(run))
      exec(run, "implement", sub_task_id: sub_task(run))

      assert [first, second] = findings(flow)
      assert first.severity == :error
      assert second.severity == :warning
      assert Enum.all?([first, second], &(&1.severity in Audit.severities()))
      assert Enum.all?([first, second], &(&1.check in Audit.checks()))
    end

    test "severities are ordered most severe first" do
      assert Audit.severities() == [:error, :warning]
    end

    test "a board with no runs has no findings" do
      board = insert(:board)
      assert findings(audit_flow(board)) == []
    end
  end

  describe "recent_runs_for_flow/2" do
    test "returns the flow's runs oldest-first with executions preloaded in id order" do
      board = insert(:board)
      flow = audit_flow(board)
      now = DateTime.truncate(DateTime.utc_now(), :second)
      newer = run_for(board, started_at: DateTime.add(now, -60))
      older = run_for(board, started_at: DateTime.add(now, -600))
      exec(newer, "implement", [])
      exec(newer, "spec_review", [])

      assert [first, second] = Runs.recent_runs_for_flow(flow, window: "all")
      assert first.id == older.id
      assert second.id == newer.id
      assert Enum.map(second.node_executions, & &1.node_key) == ["implement", "spec_review"]
    end

    test "the 7d window excludes an older run, and garbage falls back to the default" do
      board = insert(:board)
      flow = audit_flow(board)
      now = DateTime.truncate(DateTime.utc_now(), :second)
      run_for(board, started_at: DateTime.add(now, -40 * 86_400))
      run_for(board, started_at: DateTime.add(now, -60))

      assert length(Runs.recent_runs_for_flow(flow, window: "7d")) == 1
      assert length(Runs.recent_runs_for_flow(flow, window: "all")) == 2
      assert length(Runs.recent_runs_for_flow(flow, window: "nonsense")) == 1
    end
  end
end
