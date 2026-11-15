defmodule Hamaca.Runs.ExecutionCostTest do
  @moduledoc """
  RE516 — a harness reports its session's RUNNING total (Claude Code's `total_cost_usd` carries
  across `--resume`), so `finalize_job!/2` stores each execution's own share: the reported total
  minus what this card's other executions on the same session already recorded.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Runs
  alias Hamaca.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  setup do
    FakeDispatcher.register(self())
    user = insert(:user)
    {:ok, board} = Hamaca.Boards.create_board(user, %{name: unique_slug("cost-board")})
    flow = one_node_flow(board)
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Hamaca.Cards.create_card(stage, %{title: "Priced work"})
    start_engine!()
    %{board: board, flow: flow, card: card, stage: stage}
  end

  defp one_node_flow(board) do
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    :ok = clear_spec_flow!(board)

    {:ok, flow} =
      Hamaca.Flows.create_flow(board, %{
        key: "cost-flow",
        isolation: :shared_clean,
        stage_id: spec.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}"}],
        edges: [%{from: "start", to: "brainstorm"}, %{from: "brainstorm", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Hamaca.Flows.enable_flow(flow)
    flow
  end

  # A stage holds exactly one flow: take the board's seeded "spec" flow off Spec so the test flow
  # can work there.
  defp clear_spec_flow!(board) do
    if spec = Hamaca.Flows.get_flow(board, "spec") do
      {:ok, spec} = Hamaca.Flows.disable_flow(spec)
      {:ok, _} = Hamaca.Flows.delete_flow(spec)
    end

    :ok
  end

  defp start(card, flow) do
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = job}, 10_000
    {run, job}
  end

  # Park the first job on a human question, resume on `session`, and return the re-entry job.
  defp park_and_resume(run, job, first_attrs, session) do
    {:ok, _parked} = Runs.report_outcome(job, Map.merge(%{outcome: :needs_input, detail: "?"}, first_attrs))
    {:ok, _run} = run.id |> Runs.get_run!() |> Runs.resume_run(resume_session: session)
    assert_receive {:dispatched, %NodeJob{} = reentry}, 10_000
    reentry
  end

  defp cost_of(%NodeJob{node_execution_id: id}), do: Repo.get!(NodeExecution, id).cost

  test "9: a fresh session's first execution stores the reported cost raw", ctx do
    {_run, job} = start(ctx.card, ctx.flow)

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, session_id: "s-1", cost: Decimal.new("0.40")})

    assert Decimal.equal?(cost_of(job), Decimal.new("0.40"))
  end

  test "10: a resumed session stores only its delta, so the card total is the final running total", ctx do
    {run, job} = start(ctx.card, ctx.flow)
    reentry = park_and_resume(run, job, %{session_id: "s-1", cost: Decimal.new("0.30")}, "s-1")

    {:ok, _run} = Runs.report_outcome(reentry, %{outcome: :succeeded, session_id: "s-1", cost: Decimal.new("0.75")})

    assert Decimal.equal?(cost_of(reentry), Decimal.new("0.45"))
    assert Decimal.equal?(cost_of(job), Decimal.new("0.30"))
    assert Decimal.equal?(Runs.run_summary_for_card(ctx.card).card_cost, Decimal.new("0.75"))
  end

  test "11: an unpriced prior execution on the session is not subtracted", ctx do
    {run, job} = start(ctx.card, ctx.flow)
    reentry = park_and_resume(run, job, %{session_id: "s-1"}, "s-1")

    {:ok, _run} = Runs.report_outcome(reentry, %{outcome: :succeeded, session_id: "s-1", cost: Decimal.new("0.75")})

    assert cost_of(job) == nil
    assert Decimal.equal?(cost_of(reentry), Decimal.new("0.75"))
  end

  test "12: a reported total below the session's prior spend stores zero", ctx do
    {run, job} = start(ctx.card, ctx.flow)
    reentry = park_and_resume(run, job, %{session_id: "s-1", cost: Decimal.new("0.30")}, "s-1")

    {:ok, _run} = Runs.report_outcome(reentry, %{outcome: :succeeded, session_id: "s-1", cost: Decimal.new("0.10")})

    assert Decimal.equal?(cost_of(reentry), Decimal.new("0"))
  end

  test "13: a different session's spend is not subtracted", ctx do
    {run, job} = start(ctx.card, ctx.flow)
    reentry = park_and_resume(run, job, %{session_id: "s-1", cost: Decimal.new("0.30")}, "s-1")

    {:ok, _run} = Runs.report_outcome(reentry, %{outcome: :succeeded, session_id: "s-2", cost: Decimal.new("0.50")})

    assert Decimal.equal?(cost_of(reentry), Decimal.new("0.50"))
  end

  test "14: no session means no prior — the cost is stored raw", ctx do
    {_run, job} = start(ctx.card, ctx.flow)

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, session_id: nil, cost: Decimal.new("0.20")})

    assert Decimal.equal?(cost_of(job), Decimal.new("0.20"))
  end

  test "15: a blocked execution keeps its cost but still drops its session (RE308)", ctx do
    {_run, job} = start(ctx.card, ctx.flow)

    {:ok, _run} =
      Runs.report_outcome(job, %{
        outcome: :blocked,
        detail: "agent could not run: x",
        session_id: "s-b",
        cost: Decimal.new("0.05")
      })

    execution = Repo.get!(NodeExecution, job.node_execution_id)
    assert execution.session_id == nil
    assert Decimal.equal?(execution.cost, Decimal.new("0.05"))
  end

  test "16: the prior is scoped to the card — another card's spend on the same session id is not subtracted",
       ctx do
    {_run_a, job_a} = start(ctx.card, ctx.flow)
    {:ok, _run} = Runs.report_outcome(job_a, %{outcome: :succeeded, session_id: "s-1", cost: Decimal.new("0.30")})

    {:ok, card_b} = Hamaca.Cards.create_card(ctx.stage, %{title: "Other priced work"})
    {_run_b, job_b} = start(card_b, ctx.flow)
    {:ok, _run} = Runs.report_outcome(job_b, %{outcome: :succeeded, session_id: "s-1", cost: Decimal.new("0.40")})

    assert Decimal.equal?(cost_of(job_a), Decimal.new("0.30"))
    assert Decimal.equal?(cost_of(job_b), Decimal.new("0.40"))
  end
end
