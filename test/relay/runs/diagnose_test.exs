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

  test "a flow with no connected executor is awaiting_capacity", %{board: board, queue: queue, works: works} do
    insert(:flow, board: board, key: "code", enabled: true, pulls_from_stage_id: queue.id, works_in_stage_id: works.id)
    card = insert(:card, stage: queue, status: :ready)

    assert %{verdict: :awaiting_capacity, evidence: %{flow_key: "code"}} = Runs.diagnose(board, card)
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
end
