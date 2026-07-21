defmodule Relay.Runs.LastProgressTest do
  use Relay.DataCase, async: false

  alias Relay.Runs

  setup do
    board = insert(:board)
    works = insert(:stage, board: board, name: "Code", position: 1, type: :work)
    {:ok, board: board, works: works}
  end

  test "falls back to run start when there are no executions", %{works: works} do
    card = insert(:card, stage: works)
    run = insert(:run, card: card, inserted_at: DateTime.truncate(DateTime.utc_now(), :second))

    assert Runs.last_progress_at(run) == run.inserted_at
  end

  test "is the newest execution's inserted_at, and a requeue (no new execution) does not reset it",
       %{works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    old = DateTime.add(now, -900, :second)
    card = insert(:card, stage: works)
    run = insert(:run, card: card, inserted_at: DateTime.add(now, -1200, :second))
    exec = insert(:node_execution, run: run, node_key: "implement", inserted_at: old)
    # The revoke/requeue loop: the job churns, but no NEW node_executions row appears.
    insert(:node_job, node_execution: exec, state: :queued, executor_name: nil, claimed_at: nil)

    assert Runs.last_progress_at(run) == old
  end

  test "advances when a newer execution row is inserted", %{works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works)
    run = insert(:run, card: card)
    insert(:node_execution, run: run, node_key: "a", inserted_at: DateTime.add(now, -600, :second))
    insert(:node_execution, run: run, node_key: "b", inserted_at: DateTime.add(now, -60, :second))

    assert Runs.last_progress_at(run) == DateTime.add(now, -60, :second)
  end

  test "the bulk variant matches the per-run one", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works)
    run = insert(:run, card: card)
    insert(:node_execution, run: run, node_key: "a", inserted_at: DateTime.add(now, -120, :second))

    assert Runs.last_progress_by_run(board) == %{run.id => Runs.last_progress_at(run)}
  end

  test "working_run_ids includes a running job on a live executor, excludes a queued one",
       %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    insert(:executor, board: board, name: "live", last_heartbeat: now)

    card_a = insert(:card, stage: works)
    run_a = insert(:run, card: card_a)
    exec_a = insert(:node_execution, run: run_a, outcome: nil, finished_at: nil)
    insert(:node_job, node_execution: exec_a, state: :running, executor_name: "live", claimed_at: now)

    card_b = insert(:card, stage: works)
    run_b = insert(:run, card: card_b)
    exec_b = insert(:node_execution, run: run_b, outcome: nil, finished_at: nil)
    insert(:node_job, node_execution: exec_b, state: :queued, executor_name: nil, claimed_at: nil)

    ids = Runs.working_run_ids(board, now)
    assert MapSet.member?(ids, run_a.id)
    refute MapSet.member?(ids, run_b.id)
  end

  test "run_stalled? is true only when not working and past the threshold", %{} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    old = DateTime.add(now, -400, :second)
    young = DateTime.add(now, -60, :second)

    assert Runs.run_stalled?(old, false, now)
    refute Runs.run_stalled?(old, true, now)
    refute Runs.run_stalled?(young, false, now)
    refute Runs.run_stalled?(nil, false, now)
  end
end
