defmodule Relay.Runs.BlockedOutcomeTest do
  @moduledoc """
  RE308 — a node whose agent could not run at all (expired login, usage limit) reports `:blocked`.
  The run parks for a human WITHOUT spending retry budget, the card and its timeline carry the real
  cause, nothing can `--resume` the dead session, and Retry revives the run in place.
  """
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  @oauth "agent could not run: Failed to authenticate: OAuth session expired and could not be refreshed"

  setup do
    FakeDispatcher.register(self())
    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Blocked Board"})
    flow = retrying_flow(board)
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Expired login"})
    start_engine!()
    %{board: board, flow: flow, card: card}
  end

  # One agent node with retry budget to spare and NO :failed edge: were :blocked counted as a
  # failure, the run would visibly retry (a second dispatch) instead of parking.
  defp retrying_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Spec:Review"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "blocked-flow",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: review.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}", max_retries: 2}],
        edges: [%{from: "start", to: "brainstorm"}, %{from: "brainstorm", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp start(card, flow) do
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {run, job}
  end

  defp block(job), do: Runs.report_outcome(job, %{outcome: :blocked, detail: @oauth, session_id: "s-dead"})

  test "a blocked outcome parks the run and blocks the card, creating no retry job", ctx do
    {run, job} = start(ctx.card, ctx.flow)

    assert {:ok, parked} = block(job)
    assert parked.status == :parked
    assert parked.parked_reason == :needs_input

    refute_receive {:dispatched, _job}
    assert Repo.aggregate(from(j in NodeJob, where: j.run_id == ^run.id), :count) == 1

    card = Repo.get!(Schemas.Card, ctx.card.id)
    assert card.status == :needs_input

    assert Enum.any?(
             Relay.Activity.list_timeline(card),
             &match?(%Schemas.Activity{type: :failure, text: @oauth}, &1)
           )
  end

  test "the blocked attempt stores no session and no failure signature", ctx do
    {run, job} = start(ctx.card, ctx.flow)
    {:ok, _parked} = block(job)

    execution = Repo.one!(from e in NodeExecution, where: e.run_id == ^run.id)
    assert execution.outcome == :blocked
    assert execution.detail == @oauth
    assert execution.session_id == nil
    assert execution.failure_signature == nil
  end

  test "an infrastructure park is classified, restartable, and named for the restart dialog", ctx do
    {run, job} = start(ctx.card, ctx.flow)
    {:ok, _parked} = block(job)

    run = Runs.get_run!(run.id)
    assert Runs.park_kind(run) == :infrastructure
    assert Runs.restartable?(run)
    assert Runs.stall_reason(run) == "brainstorm could not run — retry"
  end

  test "Retry revives the run on the same node, fresh, and unblocks the card", ctx do
    {run, job} = start(ctx.card, ctx.flow)
    {:ok, _parked} = block(job)

    assert {:ok, revived} = Runs.retry_run(Runs.get_run!(run.id))
    assert revived.status == :running
    assert revived.current_node == "brainstorm"

    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm", payload: payload}}
    assert payload["resume_session"] == nil
    assert Repo.get!(Schemas.Card, ctx.card.id).status == :working
  end

  test "Retry after a block hands the node the finding that preceded it, not a phantom one", ctx do
    {run, first} = start(ctx.card, ctx.flow)
    {:ok, _run} = Runs.report_outcome(first, %{outcome: :failed, detail: "real finding"})
    assert_receive {:dispatched, %NodeJob{} = second}
    {:ok, _parked} = block(second)

    {:ok, _revived} = Runs.retry_run(Runs.get_run!(run.id))
    assert_receive {:dispatched, %NodeJob{payload: payload}}
    assert payload["vars"]["findings"] == "real finding"
  end
end
