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
    card = Keyword.get_lazy(opts, :card, fn -> card_on(board) end)
    now = DateTime.truncate(DateTime.utc_now(), :second)
    started_at = Keyword.get(opts, :started_at, DateTime.add(now, -60))

    insert(:run,
      card: card,
      flow_key: "code",
      status: :done,
      started_at: started_at,
      tasks_from_plan: Keyword.get(opts, :tasks_from_plan, false)
    )
  end

  defp card_on(board), do: insert(:card, board: board, stage: insert(:stage, board: board))

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

  describe "planner_not_migrated (C3)" do
    test "is silent when no run's tasks came from the plan-parse fallback" do
      board = insert(:board)
      flow = audit_flow(board)
      run_for(board)
      run_for(board)

      assert findings(flow) == []
    end

    test "warns once, naming the card, when one run's tasks came from the fallback" do
      board = insert(:board)
      flow = audit_flow(board)
      card = card_on(board)
      run = run_for(board, card: card, tasks_from_plan: true)
      run_for(board)

      assert [finding] = findings(flow)
      assert finding.severity == :warning
      assert finding.check == :planner_not_migrated
      assert finding.flow_key == "code"
      assert finding.node_key == nil
      assert finding.run_id == run.id
      ref = Relay.Cards.ref(board, card)
      assert String.starts_with?(finding.summary, "#{ref}'s tasks came from the legacy plan-parse fallback")
      assert finding.evidence =~ "run #{run.id}"
    end

    test "one finding per flow: counts distinct cards and names the most recent three" do
      board = insert(:board)
      flow = audit_flow(board)
      now = DateTime.truncate(DateTime.utc_now(), :second)
      [a, b, c, d] = for _ <- 1..4, do: card_on(board)

      run_for(board, card: a, tasks_from_plan: true, started_at: DateTime.add(now, -400))
      run_for(board, card: b, tasks_from_plan: true, started_at: DateTime.add(now, -300))
      run_for(board, card: c, tasks_from_plan: true, started_at: DateTime.add(now, -200))
      run_for(board, card: d, tasks_from_plan: true, started_at: DateTime.add(now, -100))
      latest = run_for(board, card: a, tasks_from_plan: true, started_at: DateTime.add(now, -50))

      assert [finding] = findings(flow)
      assert finding.run_id == latest.id
      assert finding.summary =~ "4 cards' tasks came from the legacy plan-parse fallback"

      refs = Enum.map([a, d, c], &Relay.Cards.ref(board, &1))
      assert finding.summary =~ "(most recent: #{Enum.join(refs, ", ")})"
      refute finding.summary =~ Relay.Cards.ref(board, b)
    end

    test "names the fix in task vocabulary" do
      board = insert(:board)
      flow = audit_flow(board)
      run_for(board, tasks_from_plan: true)

      assert [finding] = findings(flow)
      text = Enum.join([finding.summary, finding.evidence, finding.fix], "\n")
      assert text =~ "/relay-doctor"
      assert text =~ "relay tasks add"
      assert text =~ "tasks"
      refute text =~ "sub_tasks"
      refute text =~ "sub_task"
    end
  end

  describe "outcomeless_attempts (C4)" do
    # The cap is a policy owned by Relay.Runs; never re-type it here.
    defp cap, do: Runs.max_outcomeless_reentries()

    defp outcomeless(run, node, attempts, visit \\ 1) do
      Enum.each(attempts, &exec(run, node, attempt: &1, visit: visit, outcome: nil))
    end

    test "warns when one node in one visit reaches the cap of outcome-less attempts" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      outcomeless(run, "implement", 1..cap())

      assert [finding] = findings(flow)
      assert finding.severity == :warning
      assert finding.check == :outcomeless_attempts
      assert finding.node_key == "implement"
      assert finding.run_id == run.id
      assert finding.flow_key == "code"
      assert finding.summary =~ "`implement`"
      assert finding.summary =~ "#{cap()} times"
      assert finding.summary =~ "visit 1"
      assert finding.summary =~ "run #{run.id}"
      assert finding.evidence =~ "attempts #{Enum.join(1..cap(), ", ")}"
      assert finding.evidence =~ "run #{run.id}, implement visit 1"

      assert finding.fix ==
               "Something keeps killing this node's job before it reports (a server restart " <>
                 "from inside the flow?). Make the node idempotent or move the restart off the flow."
    end

    test "is silent one attempt below the cap" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      outcomeless(run, "implement", 1..(cap() - 1))

      assert findings(flow) == []
    end

    test "counts per {node, visit}, not across visits" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      outcomeless(run, "implement", 1..(cap() - 1), 1)
      outcomeless(run, "implement", [1], 2)

      assert findings(flow) == []
    end

    test "emits one finding per looping node, in node order" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      outcomeless(run, "implement", 1..cap())
      outcomeless(run, "spec_review", 1..cap())

      assert [first, second] = findings(flow)
      assert Enum.map([first, second], & &1.check) == [:outcomeless_attempts, :outcomeless_attempts]
      assert Enum.map([first, second], & &1.node_key) == ["implement", "spec_review"]
    end

    test "does not count the needs_input row the re-entry cap stamps" do
      board = insert(:board)
      flow = audit_flow(board)
      run = run_for(board)
      outcomeless(run, "implement", 1..(cap() - 1))
      exec(run, "implement", attempt: cap(), outcome: :needs_input)

      assert findings(flow) == []
    end
  end

  describe "findings/2" do
    test "checks/0 is the closed set of check ids, including outcomeless_attempts" do
      assert Audit.checks() == [:findings_dropped, :verdict_flipped, :planner_not_migrated, :outcomeless_attempts]
    end

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
      assert second.card.board.id == board.id
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
