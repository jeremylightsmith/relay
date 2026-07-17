defmodule Relay.FlowsSeedTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows
  alias Schemas.Flow

  # A board shaped like the default seed will be after Task 3: the stage
  # names the default library's triggers reference, incl. the sub-lanes.
  defp library_board do
    board = insert(:board)
    next_up = insert(:stage, board: board, name: "Next up", position: 1)
    spec = insert(:stage, board: board, name: "Spec", category: :planning, type: :planning, position: 2)
    plan = insert(:stage, board: board, name: "Plan", category: :planning, type: :planning, position: 3)
    code = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 4)
    review = insert(:stage, board: board, name: "Review", category: :in_progress, type: :review, position: 5)
    {:ok, spec_review} = Boards.enable_lane(spec, :review)
    {:ok, spec_done} = Boards.enable_lane(spec, :done)
    {:ok, plan_done} = Boards.enable_lane(plan, :done)

    %{
      board: board,
      next_up: next_up,
      spec: spec,
      plan: plan,
      code: code,
      review: review,
      spec_review: spec_review,
      spec_done: spec_done,
      plan_done: plan_done
    }
  end

  test "seeds the three default flows, disabled, triggers resolved by stage name (AC 1)" do
    ctx = library_board()

    assert :ok = Flows.seed_default_flows!(ctx.board)

    assert [%Flow{key: "code"} = code, %Flow{key: "plan"} = plan, %Flow{key: "spec"} = spec] =
             Flows.list_flows(ctx.board)

    refute Enum.any?([code, plan, spec], & &1.enabled)

    assert spec.pulls_from_stage_id == ctx.next_up.id
    assert spec.works_in_stage_id == ctx.spec.id
    assert spec.lands_on_stage_id == ctx.spec_review.id
    assert spec.isolation == :shared_clean

    assert plan.pulls_from_stage_id == ctx.spec_done.id
    assert plan.works_in_stage_id == ctx.plan.id
    assert plan.lands_on_stage_id == ctx.plan_done.id
    assert plan.isolation == :shared_clean

    assert code.pulls_from_stage_id == ctx.plan_done.id
    assert code.works_in_stage_id == ctx.code.id
    assert code.lands_on_stage_id == ctx.review.id
    assert code.isolation == :exclusive
  end

  test "translates the authored jsonc graphs faithfully" do
    ctx = library_board()
    :ok = Flows.seed_default_flows!(ctx.board)

    spec = Flows.get_flow(ctx.board, "spec")
    assert [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}", max_retries: 1, model: nil}] = spec.nodes

    assert [%{from: "start", to: "brainstorm", on: nil}, %{from: "brainstorm", to: "done", on: :succeeded}] =
             spec.edges

    plan = Flows.get_flow(ctx.board, "plan")
    assert [%{key: "write_plan", type: :agent, run: "/write-plan {ref}", max_retries: 1}] = plan.nodes

    code = Flows.get_flow(ctx.board, "code")
    assert length(code.nodes) == 14
    assert length(code.edges) == 22

    implement = Enum.find(code.nodes, &(&1.key == "implement"))
    assert %{type: :agent, model: "sonnet", effort: "high"} = implement

    assert %{type: :gate, run: "! grep -q -- '- \\[ \\]' plan.md"} =
             Enum.find(code.nodes, &(&1.key == "next_task"))

    assert %{type: :gate, run: "mix precommit"} = Enum.find(code.nodes, &(&1.key == "precommit"))
    assert %{type: :shell} = Enum.find(code.nodes, &(&1.key == "merge"))

    assert %{on: :failed, max_loops: 3} =
             Enum.find(code.edges, &(&1.from == "spec_review" and &1.to == "implement"))

    assert %{on: :succeeded} = Enum.find(code.edges, &(&1.from == "merge" and &1.to == "done"))
  end

  test "is idempotent and never clobbers edits (AC 2)" do
    ctx = library_board()
    :ok = Flows.seed_default_flows!(ctx.board)

    spec = Flows.get_flow(ctx.board, "spec")

    {:ok, _} =
      Flows.update_flow(spec, %{
        nodes: [%{key: "brainstorm", type: :agent, run: "/my-custom-brainstorm {ref}", max_retries: 1}]
      })

    assert :ok = Flows.seed_default_flows!(ctx.board)

    assert length(Flows.list_flows(ctx.board)) == 3
    assert [%{run: "/my-custom-brainstorm {ref}"}] = Flows.get_flow(ctx.board, "spec").nodes
  end

  test "a board missing a trigger sub-lane seeds that trigger as nil; the flow can't be enabled" do
    board = insert(:board)
    insert(:stage, board: board, name: "Next up", position: 1)
    spec = insert(:stage, board: board, name: "Spec", category: :planning, type: :planning, position: 2)
    plan = insert(:stage, board: board, name: "Plan", category: :planning, type: :planning, position: 3)
    insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 4)
    insert(:stage, board: board, name: "Review", category: :in_progress, type: :review, position: 5)
    {:ok, _} = Boards.enable_lane(spec, :review)
    {:ok, _} = Boards.enable_lane(spec, :done)
    # No Plan:Done — the plan flow's lands_on and the code flow's pulls_from won't resolve.

    assert :ok = Flows.seed_default_flows!(board)

    plan_flow = Flows.get_flow(board, "plan")
    assert plan_flow.lands_on_stage_id == nil
    assert plan_flow.works_in_stage_id == plan.id
    assert Flows.get_flow(board, "code").pulls_from_stage_id == nil

    assert {:error, changeset} = Flows.enable_flow(plan_flow)
    assert %{lands_on_stage_id: ["must be set before the flow can be enabled"]} = errors_on(changeset)
  end
end
