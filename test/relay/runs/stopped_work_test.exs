defmodule Relay.Runs.StoppedWorkTest do
  use Relay.DataCase, async: false

  alias Relay.Runs

  setup do
    Relay.Runs.Capacity.reset()
    board = insert(:board)
    queue = insert(:stage, board: board, name: "Plan:Done", position: 1, type: :queue)
    works = insert(:stage, board: board, name: "Code", position: 2, type: :work)
    insert(:flow, board: board, key: "code", enabled: true, pulls_from_stage_id: queue.id, works_in_stage_id: works.id)
    {:ok, board: board, queue: queue, works: works}
  end

  # A queued, unclaimed node-job on this board, inserted `age_s` ago.
  defp queued_job(works, age_s) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    at = DateTime.add(now, -age_s, :second)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running)
    exec = insert(:node_execution, run: run, outcome: nil, finished_at: nil, inserted_at: at)
    insert(:node_job, node_execution: exec, state: :queued, executor_name: nil, claimed_at: nil, inserted_at: at)
  end

  test "nil when the board is quiet — no queued jobs", %{board: board} do
    assert Runs.stopped_work(board) == nil
  end

  test "nil when jobs are queued but every executor is busy and current (criterion 4)", %{board: board, works: works} do
    queued_job(works, 600)
    # A fresh, current executor with zero free slots: busy, not stopped.
    insert(:executor,
      board: board,
      name: "busy",
      version: Runs.min_executor_version(),
      capacity: %{"shared_clean" => 0, "exclusive" => 0}
    )

    assert Runs.stopped_work(board) == nil
  end

  test ":executor_outdated with the version pair when the only executor is refused", %{board: board, works: works} do
    queued_job(works, 600)
    insert(:executor, board: board, name: "old", version: 0)

    assert %{reason: :executor_outdated, detail: detail, queued_count: 1, evidence: evidence} =
             Runs.stopped_work(board)

    assert detail =~ "No jobs claimed in"
    assert detail =~ "requires v#{Runs.min_executor_version()}"
    assert evidence.required_version == Runs.min_executor_version()
  end

  test ":no_executor on an empty roster", %{board: board, works: works} do
    queued_job(works, 600)

    assert %{reason: :no_executor, detail: detail} = Runs.stopped_work(board)
    assert detail =~ "no executor is connected"
  end

  test ":executor_gone when the roster's executors have all gone silent", %{board: board, works: works} do
    queued_job(works, 600)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    insert(:executor,
      board: board,
      name: "silent",
      version: Runs.min_executor_version(),
      last_heartbeat: DateTime.add(now, -3600, :second)
    )

    assert %{reason: :executor_gone} = Runs.stopped_work(board)
  end

  test "nil when the oldest queued job is younger than the threshold", %{board: board, works: works} do
    queued_job(works, 30)
    insert(:executor, board: board, name: "old", version: 0)

    assert Runs.stopped_work(board) == nil
  end
end
