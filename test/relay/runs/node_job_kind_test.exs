defmodule Relay.Runs.NodeJobKindTest do
  @moduledoc """
  RE268 — the regression that matters when two dispatchers share one table: a talk job is never
  returned to a flow claim, and a node job is never returned to a talk claim (ADR 0009).
  """
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Schemas.NodeJob

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    card = insert(:card, board: board, stage: stage)
    executor = insert(:executor, board: board, name: "mac-1", capacity: %{"shared_clean" => 1, "exclusive" => 1})
    %{board: board, card: card, executor: executor}
  end

  test "the kinds are a closed set with the flow partition named once" do
    assert NodeJob.kinds() == [:node, :talk]
    assert NodeJob.flow_kinds() == [:node]
    assert NodeJob.talk_kind() == :talk
    refute NodeJob.talk_kind() in NodeJob.flow_kinds()
  end

  test "a flow job is inserted with kind :node and its run's card", ctx do
    run = insert(:run, card: ctx.card)
    execution = insert(:node_execution, run: run)
    job = Runs.insert_job!(run, execution, %{"isolation" => "shared_clean"})

    assert job.kind == :node
    assert job.card_id == ctx.card.id
  end

  test "a talk job carries no run and is claimable by any executor", ctx do
    job = Runs.insert_talk_job!(ctx.card, %{"turn_id" => 1, "prompt" => "why is this stuck?"}, nil)

    assert job.kind == :talk
    assert is_nil(job.run_id)
    assert is_nil(job.node_execution_id)
    assert job.card_id == ctx.card.id

    assert {:ok, claimed} = Runs.claim_next_job(ctx.executor)
    assert claimed.id == job.id
    assert claimed.state == :claimed
    assert claimed.executor_name == "mac-1"
  end

  test "a talk job pinned to another executor is never offered here", ctx do
    Runs.insert_talk_job!(ctx.card, %{"turn_id" => 1}, "other-box")

    assert {:ok, nil} = Runs.claim_next_job(ctx.executor)
  end

  test "a talk job is claimable even when no isolation capacity is advertised", ctx do
    idle = insert(:executor, board: ctx.board, name: "mac-2", capacity: %{"shared_clean" => 0, "exclusive" => 0})
    job = Runs.insert_talk_job!(ctx.card, %{"turn_id" => 1}, nil)

    assert {:ok, claimed} = Runs.claim_next_job(idle)
    assert claimed.id == job.id
  end

  test "a talk job is never reported through the flow outcome path", ctx do
    job = Runs.insert_talk_job!(ctx.card, %{"turn_id" => 1}, nil)
    {:ok, claimed} = Runs.claim_next_job(ctx.executor)

    assert {:error, :not_found} = Runs.get_claimed_job(ctx.board, claimed.id)
    assert Runs.get_job(job.id).kind == :talk
  end

  test "revoking a talk job makes the heartbeat name it for this executor", ctx do
    Runs.insert_talk_job!(ctx.card, %{"turn_id" => 1}, nil)
    {:ok, claimed} = Runs.claim_next_job(ctx.executor)

    assert Runs.revoked_among(ctx.board, [claimed.id]) == []
    assert :ok = Runs.revoke_talk_job(claimed)
    assert Runs.revoked_among(ctx.board, [claimed.id]) == [claimed.id]
    assert {:error, :not_active} = Runs.revoke_talk_job(Runs.get_job(claimed.id))
  end

  test "revoke refuses a flow job — those end through the run lifecycle", ctx do
    run = insert(:run, card: ctx.card)
    execution = insert(:node_execution, run: run)
    job = Runs.insert_job!(run, execution, %{"isolation" => "shared_clean"})

    assert_raise FunctionClauseError, fn -> Runs.revoke_talk_job(job) end
  end

  test "a talk job never refreshes the card's agent heartbeat", ctx do
    Runs.insert_talk_job!(ctx.card, %{"turn_id" => 1}, nil)
    {:ok, claimed} = Runs.claim_next_job(ctx.executor)

    assert {0, _} = Runs.refresh_running_card_liveness(ctx.board, [claimed.id])
  end

  test "a talk job is never requeued by the orphan reaper", ctx do
    Runs.insert_talk_job!(ctx.card, %{"turn_id" => 1}, nil)
    {:ok, claimed} = Runs.claim_next_job(ctx.executor)

    :ok = Runs.requeue_orphaned_jobs(ctx.board, ctx.executor, [])

    assert Runs.get_job(claimed.id).state == :claimed
  end

  test "finishing a talk job is terminal", ctx do
    Runs.insert_talk_job!(ctx.card, %{"turn_id" => 1}, nil)
    {:ok, claimed} = Runs.claim_next_job(ctx.executor)

    finished = Runs.finish_talk_job!(claimed)
    assert finished.state == :done
    assert finished.finished_at
  end

  test "plan_task_count counts the plan's task headings" do
    assert Runs.plan_task_count(nil) == 0
    assert Runs.plan_task_count("## Task 1: A\n\n## Task 2: B\n") == 2
  end
end
