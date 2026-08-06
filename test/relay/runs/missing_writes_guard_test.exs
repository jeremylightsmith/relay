defmodule Relay.Runs.MissingWritesGuardTest do
  @moduledoc """
  RE244 §3, mirroring `no_op_guard_test.exs`. A node that declares it fills a card field and
  reports `:succeeded` with that field still blank has not done its work — the "empty spec
  reached Spec:Review" failure class.
  """
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Missing Writes Board"})
    start_engine!()
    :ok = Runs.subscribe(board.id)
    %{board: board}
  end

  # One agent node carrying whatever contract the test needs, with the real Spec flow's
  # retry-once-then-park shape available via `max_retries`.
  defp contract_flow(board, node_attrs) do
    pulls = Enum.find(board.stages, &(&1.name == "Next up"))
    works = Enum.find(board.stages, &(&1.name == "Spec"))
    lands = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "contract-#{System.unique_integer([:positive])}",
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id,
        nodes: [Map.merge(%{key: "work", type: :agent, run: "/work {ref}"}, node_attrs)],
        edges: [
          %{from: "start", to: "work"},
          %{from: "work", to: "done", on: :succeeded},
          %{from: "work", to: "needs_input", on: :failed}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp start_work(board, flow, card_attrs) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, Map.merge(%{title: "missing writes"}, card_attrs))
    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{node_key: "work"} = job}
    job
  end

  defp outcome_of(job), do: Repo.get!(NodeExecution, job.node_execution_id)

  test "a declared write left blank rewrites succeeded to failed", ctx do
    flow = contract_flow(ctx.board, %{writes: [:spec]})
    job = start_work(ctx.board, flow, %{})

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "all done"})

    exec = outcome_of(job)
    assert exec.outcome == :failed
    assert exec.detail =~ "missing_writes: work"
    assert exec.detail =~ "`spec`"
    assert exec.failure_signature
  end

  test "the same node keeps its success when the declared field is set", ctx do
    flow = contract_flow(ctx.board, %{writes: [:spec]})
    job = start_work(ctx.board, flow, %{spec: "# The spec"})

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "all done"})

    assert outcome_of(job).outcome == :succeeded
  end

  test "a whitespace-only field counts as blank", ctx do
    flow = contract_flow(ctx.board, %{writes: [:spec]})
    job = start_work(ctx.board, flow, %{spec: "   \n\t "})

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "all done"})

    assert outcome_of(job).outcome == :failed
  end

  # Why a node that declares nothing stays unaffected — which is what protects a hand-customized
  # (version > 1) flow that `Flows.sync_defaults!/0` skips at deploy.
  test "a node declaring no contract is untouched, even on a wholly blank card", ctx do
    flow = contract_flow(ctx.board, %{})
    job = start_work(ctx.board, flow, %{})

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "all done"})

    assert outcome_of(job).outcome == :succeeded
  end

  test "a reported :failed is not rewritten — the guard only ever demotes a success", ctx do
    flow = contract_flow(ctx.board, %{writes: [:spec]})
    job = start_work(ctx.board, flow, %{})

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :failed, detail: "boom"})

    exec = outcome_of(job)
    assert exec.outcome == :failed
    assert exec.detail == "boom"
    refute exec.detail =~ "missing_writes"
  end

  # Decision 3: reads is advisory. A card with a title and no description is legitimate.
  test "a blank `reads` field never fails the node", ctx do
    flow = contract_flow(ctx.board, %{reads: [:description]})
    job = start_work(ctx.board, flow, %{})

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "ok"})

    assert outcome_of(job).outcome == :succeeded
  end

  test "a nil ai_result and an empty sub_tasks list both count as blank", ctx do
    flow = contract_flow(ctx.board, %{writes: [:ai_result, :sub_tasks]})
    job = start_work(ctx.board, flow, %{})

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "ok"})

    exec = outcome_of(job)
    assert exec.outcome == :failed
    assert exec.detail =~ "`ai_result`"
    assert exec.detail =~ "`sub_tasks`"
  end

  # From here it is an ordinary failure: existing edges route it, no engine change.
  test "the demoted node parks the run once its retry budget is spent", ctx do
    flow = contract_flow(ctx.board, %{writes: [:spec], max_retries: 1})
    job = start_work(ctx.board, flow, %{})

    {:ok, %{status: :running}} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "x"})
    assert_receive {:dispatched, %NodeJob{node_key: "work"} = retry}

    {:ok, run} = Runs.report_outcome(retry, %{outcome: :succeeded, detail: "x"})
    assert run.status == :parked
    assert run.parked_reason == :needs_input
  end
end
