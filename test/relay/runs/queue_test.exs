defmodule Relay.Runs.QueueTest do
  @moduledoc """
  RE307 — `list_queue/2` is the read `POST /api/node-jobs/claim` cannot be: it must show the
  jobs NOBODY holds (the `executor_name` filter that made `active_jobs_by_executor/1` blind to
  them) and the talk turns that carry no run (the inner `Run` join that made every other job
  read flow-only).
  """
  use Relay.DataCase, async: true

  alias Relay.Runs

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    %{board: board, stage: stage}
  end

  # A flow (`:node`) job on `stage`'s board. `:age_s` backdates `inserted_at` for a queued job
  # and `claimed_at` for a claimed one — i.e. "how long it has been in this state".
  defp flow_job(stage, opts) do
    at = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -(opts[:age_s] || 0), :second)
    card = insert(:card, stage: stage, title: opts[:title] || "Ship the thing")
    run = insert(:run, card: card, flow_key: opts[:flow_key] || "code")
    ne = insert(:node_execution, run: run, node_key: opts[:node_key] || "implement")

    job = insert_flow_job(opts[:state] || :queued, ne, opts, at)

    %{card: card, job: job, run: run}
  end

  defp insert_flow_job(:queued, ne, opts, at) do
    insert(:node_job,
      node_execution: ne,
      payload: %{"isolation" => opts[:isolation] || "shared_clean"},
      state: :queued,
      executor_name: opts[:executor_name],
      claimed_at: nil,
      inserted_at: at
    )
  end

  defp insert_flow_job(state, ne, opts, at) do
    insert(:node_job,
      node_execution: ne,
      payload: %{"isolation" => opts[:isolation] || "shared_clean"},
      state: state,
      executor_name: opts[:executor_name] || "mac-mini",
      claimed_at: at
    )
  end

  defp refs(rows), do: Enum.map(rows, & &1.ref)

  test "a queued job NOBODY has claimed is in the queue", %{board: board, stage: stage} do
    %{card: card, job: job} = flow_job(stage, state: :queued)

    assert [row] = Runs.list_queue(board)
    assert row.job_id == job.id
    assert row.state == :queued
    assert row.kind == :node
    assert row.ref == Relay.Cards.ref(board, card)
    assert row.title == "Ship the thing"
    assert row.node_key == "implement"
    assert row.flow_key == "code"
    assert row.isolation == "shared_clean"
    assert row.executor_name == nil
  end

  test "a claimed job is in the queue, carrying the executor holding it", %{board: board, stage: stage} do
    flow_job(stage, state: :claimed, executor_name: "mac-mini")

    assert [row] = Runs.list_queue(board)
    assert row.state == :claimed
    assert row.executor_name == "mac-mini"
  end

  test "a talk turn appears with no flow key and no isolation — the LEFT join", %{board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Talk to me")
    Runs.insert_talk_job!(card, %{"turn_id" => 1}, nil)

    assert [row] = Runs.list_queue(board)
    assert row.kind == :talk
    assert row.state == :queued
    assert row.node_key == "talk"
    assert row.flow_key == nil
    assert row.isolation == nil
  end

  test "another board's jobs never appear", %{board: board, stage: stage} do
    other_stage = insert(:stage, board: insert(:board))
    flow_job(other_stage, state: :queued)
    %{card: mine} = flow_job(stage, state: :queued)

    assert refs(Runs.list_queue(board)) == [Relay.Cards.ref(board, mine)]
  end

  test "terminal jobs never appear", %{board: board, stage: stage} do
    flow_job(stage, state: :done)
    flow_job(stage, state: :revoked)

    assert Runs.list_queue(board) == []
  end

  test "queued rows come first in claim order, claimed rows after in claim-time order",
       %{board: board, stage: stage} do
    # Inserted out of order on purpose: the ordering must be the server's, not insertion luck.
    %{card: claimed_new} = flow_job(stage, state: :claimed, age_s: 10)
    %{card: queued_first} = flow_job(stage, state: :queued, age_s: 300)
    %{card: claimed_old} = flow_job(stage, state: :claimed, age_s: 600)
    %{card: queued_second} = flow_job(stage, state: :queued, age_s: 60)

    assert refs(Runs.list_queue(board)) == [
             Relay.Cards.ref(board, queued_first),
             Relay.Cards.ref(board, queued_second),
             Relay.Cards.ref(board, claimed_old),
             Relay.Cards.ref(board, claimed_new)
           ]
  end

  test "a queued job PINNED to an executor still sorts with the queued rows", %{board: board, stage: stage} do
    %{card: pinned} = flow_job(stage, state: :queued, executor_name: "mac-mini")
    %{card: claimed} = flow_job(stage, state: :claimed, age_s: 600)

    assert refs(Runs.list_queue(board)) == [Relay.Cards.ref(board, pinned), Relay.Cards.ref(board, claimed)]
  end

  test "age_s is measured off the injected now — queued from inserted_at, claimed from claimed_at",
       %{board: board, stage: stage} do
    now = DateTime.utc_now()
    flow_job(stage, state: :queued, age_s: 90)
    flow_job(stage, state: :claimed, age_s: 30)

    assert [queued, claimed] = Runs.list_queue(board, now)
    assert_in_delta queued.age_s, 90, 2
    assert_in_delta claimed.age_s, 30, 2

    # Ten minutes later, the same rows are ten minutes older — no sleeping required.
    assert [later, _] = Runs.list_queue(board, DateTime.add(now, 600, :second))
    assert_in_delta later.age_s, 690, 2
  end

  test "the per-executor jobs list is still flow-only — a talk job never enters it",
       %{board: board, stage: stage} do
    insert(:executor, board: board, name: "mac-mini")
    card = insert(:card, stage: stage)
    Runs.insert_talk_job!(card, %{"turn_id" => 1}, "mac-mini")
    %{job: flow} = flow_job(stage, state: :claimed, executor_name: "mac-mini")

    assert [%{jobs: jobs}] = Runs.list_executor_status(board)
    assert Enum.map(jobs, & &1.job_id) == [flow.id]
  end
end
