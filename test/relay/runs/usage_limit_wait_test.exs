defmodule Relay.Runs.UsageLimitWaitTest do
  @moduledoc """
  RE267 — a node refused by a Claude usage limit whose reset the runner knows goes straight back on
  the queue: the run stays `running`, the card keeps the AI baton, and the new job carries the
  blocked job's payload verbatim. The card timeline says why. After
  `Engine.max_usage_limit_waits/0` waits in a row it parks exactly as RE308 does.
  """
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.Runs.Engine
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  @limited "agent could not run: You've hit your usage limit · resets 15:00"

  setup do
    FakeDispatcher.register(self())
    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Usage Limit Board"})
    flow = waiting_flow(board)
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Limited"})
    start_engine!()
    %{board: board, flow: flow, card: card}
  end

  defp waiting_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Spec:Review"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "wait-flow",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: review.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}", max_retries: 1}],
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

  defp in_an_hour, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

  defp hit_limit(job, resume_at),
    do: Runs.report_outcome(job, %{outcome: :blocked, detail: @limited, resume_at: resume_at})

  defp waits_logged(card) do
    card
    |> Relay.Activity.list_timeline()
    |> Enum.filter(&match?(%Schemas.Activity{text: "usage limit — waiting" <> _}, &1))
  end

  test "a known reset requeues the same node with the blocked job's payload", ctx do
    {run, job} = start(ctx.card, ctx.flow)
    original_payload = Repo.get!(NodeJob, job.id).payload

    assert {:ok, still} = hit_limit(job, in_an_hour())
    assert still.status == :running
    assert still.current_node == "brainstorm"

    assert_receive {:dispatched, %NodeJob{} = requeued}
    requeued = Repo.get!(NodeJob, requeued.id)
    assert requeued.id != job.id
    assert requeued.state == :queued
    assert requeued.node_key == "brainstorm"
    assert requeued.payload == original_payload

    [blocked, next] = Repo.all(from e in NodeExecution, where: e.run_id == ^run.id, order_by: e.id)
    assert blocked.outcome == :blocked
    assert %DateTime{} = blocked.resume_at
    assert {next.node_key, next.visit, next.attempt, next.outcome} == {"brainstorm", 1, 2, nil}

    refute Repo.get!(Schemas.Card, ctx.card.id).status == :needs_input
  end

  test "the timeline says why the work paused, and logs no failure", ctx do
    {_run, job} = start(ctx.card, ctx.flow)
    at = in_an_hour()
    {:ok, _still} = hit_limit(job, at)

    card = Repo.get!(Schemas.Card, ctx.card.id)
    assert [entry] = waits_logged(card)
    assert entry.type == :action

    assert entry.text ==
             "usage limit — waiting for reset at #{Runs.resume_time_label(at)}; " <>
               "node brainstorm will re-run (wait 1 of #{Engine.max_usage_limit_waits()})"

    refute Enum.any?(Relay.Activity.list_timeline(card), &match?(%Schemas.Activity{type: :failure}, &1))
  end

  test "the wait past the cap parks with the RE308 infrastructure face", ctx do
    {run, first} = start(ctx.card, ctx.flow)

    last =
      Enum.reduce(1..Engine.max_usage_limit_waits(), first, fn _n, job ->
        assert {:ok, %{status: :running}} = hit_limit(job, in_an_hour())
        assert_receive {:dispatched, %NodeJob{} = next}
        next
      end)

    assert {:ok, parked} = hit_limit(last, in_an_hour())
    assert parked.status == :parked
    refute_receive {:dispatched, _job}

    card = Repo.get!(Schemas.Card, ctx.card.id)
    assert card.status == :needs_input
    assert length(waits_logged(card)) == Engine.max_usage_limit_waits()
    assert Enum.any?(Relay.Activity.list_timeline(card), &match?(%Schemas.Activity{type: :failure, text: @limited}, &1))

    run = Runs.get_run!(run.id)
    assert Runs.park_kind(run) == :infrastructure
    assert Runs.restartable?(run)
  end

  test "a block with no reset time still parks exactly as RE308", ctx do
    {run, job} = start(ctx.card, ctx.flow)

    assert {:ok, parked} = hit_limit(job, nil)
    assert parked.status == :parked
    refute_receive {:dispatched, _job}
    assert Repo.one!(from e in NodeExecution, where: e.run_id == ^run.id).resume_at == nil
  end

  test "resume_at is never stored on a non-blocked outcome", ctx do
    {run, job} = start(ctx.card, ctx.flow)
    {:ok, _done} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "ok", resume_at: in_an_hour()})
    assert Repo.one!(from e in NodeExecution, where: e.run_id == ^run.id).resume_at == nil
  end
end
