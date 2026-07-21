defmodule Relay.Runs.DiagnoseTest do
  use Relay.DataCase, async: false

  alias Relay.Runs

  setup do
    Relay.Runs.Capacity.reset()
    board = insert(:board)
    queue = insert(:stage, board: board, name: "Plan:Done", position: 1, type: :queue)
    works = insert(:stage, board: board, name: "Code", position: 2, type: :work)
    {:ok, board: board, queue: queue, works: works}
  end

  test "a card no enabled flow pulls from says so", %{board: board, queue: queue} do
    card = insert(:card, stage: queue, status: :ready)

    assert %{verdict: :no_enabled_flow, detail: detail} = Runs.diagnose(board, card)
    assert detail =~ "no enabled flow"
  end

  test "a flow with no connected executor is no_executor", %{board: board, queue: queue, works: works} do
    insert(:flow, board: board, key: "code", enabled: true, pulls_from_stage_id: queue.id, works_in_stage_id: works.id)
    card = insert(:card, stage: queue, status: :ready)

    assert %{verdict: :no_executor, evidence: %{flow_key: "code"}} = Runs.diagnose(board, card)
  end

  test "an outdated-only roster surfaces :executor_outdated through diagnose", %{board: board, queue: queue, works: works} do
    insert(:flow, board: board, key: "code", enabled: true, pulls_from_stage_id: queue.id, works_in_stage_id: works.id)
    insert(:executor, board: board, name: "old", version: 0)
    card = insert(:card, stage: queue, status: :ready)

    assert %{verdict: :executor_outdated, detail: detail, evidence: evidence} = Runs.diagnose(board, card)
    assert detail =~ "requires v#{Runs.min_executor_version()}"
    assert evidence.required_version == Runs.min_executor_version()
  end

  test ":job_stranded still overrides :executor_outdated", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    insert(:executor, board: board, name: "old", version: 0, last_heartbeat: DateTime.add(now, -3600, :second))
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running, current_node: "implement")
    execution = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)

    insert(:node_job,
      node_execution: execution,
      state: :claimed,
      executor_name: "old",
      claimed_at: DateTime.add(now, -3600, :second)
    )

    assert %{verdict: :job_stranded} = Runs.diagnose(board, card, now)
  end

  test "a live run whose job is stuck behind an outdated executor diagnoses as :executor_outdated",
       %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    insert(:executor, board: board, name: "old", version: 0, last_heartbeat: now)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running, current_node: "implement")
    exec = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)
    insert(:node_job, node_execution: exec, state: :queued, executor_name: nil, claimed_at: nil)

    assert %{verdict: :executor_outdated, detail: detail} = Runs.diagnose(board, card, now)
    assert detail =~ "requires v#{Runs.min_executor_version()}"
  end

  test "a failed run names the node and carries the whole failure detail", %{board: board, works: works} do
    card = insert(:card, stage: works, status: :working)
    detail = String.duplicate("boom.\n\n", 400)
    run = insert(:run, card: card, status: :failed, current_node: nil, failure_detail: detail)
    insert(:node_execution, run: run, node_key: "final_review", outcome: :failed, detail: detail)

    assert %{verdict: :run_failed, detail: sentence, evidence: evidence} = Runs.diagnose(board, card)
    assert sentence =~ "final_review"
    assert evidence.last_execution.node_key == "final_review"
    assert evidence.last_execution.outcome == :failed
    assert evidence.last_execution.detail == detail
  end

  test "a claimed job past the grace with a dead executor is stranded", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running, current_node: "implement")
    execution = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)

    insert(:node_job,
      node_execution: execution,
      state: :claimed,
      executor_name: "ghost",
      claimed_at: DateTime.add(now, -3600, :second)
    )

    insert(:executor, board: board, name: "ghost", last_heartbeat: DateTime.add(now, -3600, :second))

    assert %{verdict: :job_stranded, detail: detail, evidence: %{job: job}} = Runs.diagnose(board, card, now)
    assert detail =~ "ghost"
    assert job.state == :claimed
  end

  test "a live run with a fresh executor stays run_active", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running, current_node: "implement")
    execution = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)
    insert(:node_job, node_execution: execution, state: :running, executor_name: "mac", claimed_at: now)
    insert(:executor, board: board, name: "mac", last_heartbeat: now)

    assert %{verdict: :run_active, evidence: %{current_node: "implement"}} = Runs.diagnose(board, card, now)
  end

  # A parked run (run != nil) short-circuits explain/2 to run_verdict before the flow
  # lookup matters, so these tests need no flow — just the run + its pinned executor row.
  test "a parked pinned run names the executor and its freshness", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works, status: :working)

    insert(:run,
      card: card,
      status: :parked,
      parked_reason: :executor_gone,
      current_node: nil,
      pinned_executor_name: "exec-a"
    )

    # exec-a's row exists but its last beat is long past the stale threshold → gone.
    insert(:executor, board: board, name: "exec-a", last_heartbeat: DateTime.add(now, -3600, :second))

    assert %{verdict: :awaiting_capacity, detail: detail, evidence: evidence} = Runs.diagnose(board, card, now)
    assert detail =~ ~s(executor "exec-a")
    assert detail =~ "gone"
    assert evidence.pinned_executor_name == "exec-a"
    assert evidence.pinned_executor_freshness == :gone
  end

  test "a parked pinned run whose executor row is absent says so", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works, status: :working)

    insert(:run,
      card: card,
      status: :parked,
      parked_reason: :executor_gone,
      current_node: nil,
      pinned_executor_name: "exec-ghost"
    )

    assert %{detail: detail, evidence: evidence} = Runs.diagnose(board, card, now)
    assert detail =~ "not currently connected"
    assert evidence.pinned_executor_freshness == :absent
  end
end
