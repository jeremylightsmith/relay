defmodule Relay.FlowsSeedTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Repo
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

  test "seeds the three default flows, disabled, each on its trigger stage (AC 1, RE429)" do
    ctx = library_board()

    assert :ok = Flows.seed_default_flows!(ctx.board)

    assert [%Flow{key: "code"} = code, %Flow{key: "plan"} = plan, %Flow{key: "spec"} = spec] =
             Flows.list_flows(ctx.board)

    refute Enum.any?([code, plan, spec], & &1.enabled)

    assert spec.stage_id == ctx.spec.id
    assert spec.isolation == :shared_clean

    assert plan.stage_id == ctx.plan.id
    assert plan.isolation == :shared_clean

    assert code.stage_id == ctx.code.id
    assert code.isolation == :exclusive
  end

  test "the authored JSON graphs seed faithfully" do
    ctx = library_board()
    :ok = Flows.seed_default_flows!(ctx.board)

    spec = Flows.get_flow(ctx.board, "spec")
    assert [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}", max_retries: 1, model: nil}] = spec.nodes

    assert [
             %{from: "start", to: "brainstorm", on: nil},
             %{from: "brainstorm", to: "done", on: :succeeded},
             %{from: "brainstorm", to: "needs_input", on: :failed}
           ] = spec.edges

    plan = Flows.get_flow(ctx.board, "plan")
    assert [%{key: "write_plan", type: :agent, run: "/write-plan {ref}", max_retries: 1}] = plan.nodes

    code = Flows.get_flow(ctx.board, "code")
    assert length(code.nodes) == 21
    assert length(code.edges) == 44

    # The next_task grep-gate is gone: "which task is next" is engine-derived now.
    refute Enum.any?(code.nodes, &(&1.key == "next_task"))
    assert %{foreach: "card.tasks"} = Enum.find(code.nodes, &(&1.key == "implement"))

    implement = Enum.find(code.nodes, &(&1.key == "implement"))
    assert %{type: :agent, model: "opus", effort: "high"} = implement

    assert %{type: :gate, run: "mix precommit"} = Enum.find(code.nodes, &(&1.key == "precommit"))
    assert %{type: :shell} = Enum.find(code.nodes, &(&1.key == "merge"))

    assert %{on: :failed, max_loops: 3} =
             Enum.find(code.edges, &(&1.from == "spec_review" and &1.to == "fix_findings"))

    assert %{on: :succeeded} = Enum.find(code.edges, &(&1.from == "post" and &1.to == "done"))

    # Two edges leave quality_review on the SAME outcome, split by their guard.
    assert %{to: "implement", when: :foreach_remaining} =
             Enum.find(code.edges, &(&1.from == "quality_review" and &1.when == :foreach_remaining))

    assert %{to: "sync", when: :foreach_exhausted} =
             Enum.find(code.edges, &(&1.from == "quality_review" and &1.when == :foreach_exhausted))

    # RLY-241: the JSON files ARE the library, so the shipped expects_commits marks must
    # survive the file → Document.decode! → changeset → row path.
    assert code.nodes |> Enum.filter(& &1.expects_commits) |> Enum.map(& &1.key) |> Enum.sort() ==
             ["final_fix", "fix_findings", "implement"]

    assert Enum.find(code.nodes, &(&1.key == "implement")).foreach == "card.tasks"

    assert code.edges
           |> Enum.filter(&(&1.from == "quality_review" and &1.on == :succeeded))
           |> Enum.map(& &1.when)
           |> Enum.sort() == [:foreach_exhausted, :foreach_remaining]
  end

  test "the Code flow's agent nodes name their .claude/agents definition" do
    ctx = library_board()
    :ok = Flows.seed_default_flows!(ctx.board)
    code = Flows.get_flow(ctx.board, "code")

    mapping = %{
      "implement" => "plan-implementer",
      "spec_review" => "spec-reviewer",
      "quality_review" => "quality-reviewer",
      "final_review" => "final-reviewer",
      "final_fix" => "final-fixer",
      "fix_findings" => "final-fixer",
      "smoke" => "smoke-tester",
      "acceptance" => "acceptance-tester",
      "github_fix" => "ci-fixer"
    }

    for {key, agent} <- mapping do
      assert %{agent: ^agent} = Enum.find(code.nodes, &(&1.key == key)), "#{key} must name #{agent}"
      assert File.exists?(Path.join([File.cwd!(), ".claude", "agents", "#{agent}.md"]))
    end

    # post keeps a bare prompt — no agent file exists.
    assert %{agent: nil} = Enum.find(code.nodes, &(&1.key == "post"))
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

  test "14. a library flow whose stage the board lacks is skipped, never seeded stageless (RE429)" do
    board = insert(:board)
    insert(:stage, board: board, name: "Next up", position: 1)
    spec = insert(:stage, board: board, name: "Spec", category: :planning, type: :planning, position: 2)
    code = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 3)
    {:ok, _} = Boards.enable_lane(spec, :review)

    assert :ok = Flows.seed_default_flows!(board)

    assert Flows.get_flow(board, "spec").stage_id == spec.id
    assert Flows.get_flow(board, "code").stage_id == code.id
    assert Flows.get_flow(board, "plan") == nil
    assert Repo.aggregate(from(f in Flow, where: is_nil(f.stage_id)), :count) == 0
  end

  test "15. a library flow is not seeded onto a stage that already holds a flow (RE429)" do
    ctx = library_board()

    {:ok, mine} =
      Flows.create_flow(ctx.board, %{
        key: "my-spec",
        isolation: :shared_clean,
        stage_id: ctx.spec.id,
        nodes: [],
        edges: [%{from: "start", to: "done"}]
      })

    assert :ok = Flows.seed_default_flows!(ctx.board)
    assert Flows.get_flow(ctx.board, "spec") == nil
    assert Flows.get_flow(ctx.board, "my-spec").updated_at == mine.updated_at
    assert Flows.get_flow(ctx.board, "my-spec").stage_id == ctx.spec.id

    keys = ctx.board |> Flows.list_flows() |> Enum.map(& &1.key)
    assert :ok = Flows.seed_default_flows!(ctx.board)
    assert ctx.board |> Flows.list_flows() |> Enum.map(& &1.key) == keys
    assert keys == ["code", "my-spec", "plan"]
  end

  test "the seeded flows carry the card contract and still read as uncustomized (RE244)" do
    ctx = library_board()
    :ok = Flows.seed_default_flows!(ctx.board)

    brainstorm = Enum.find(Flows.get_flow(ctx.board, "spec").nodes, &(&1.key == "brainstorm"))
    assert brainstorm.reads == [:description]
    assert brainstorm.writes == [:spec, :acceptance_criteria]

    write_plan = Enum.find(Flows.get_flow(ctx.board, "plan").nodes, &(&1.key == "write_plan"))
    assert write_plan.reads == [:spec, :acceptance_criteria]
    assert write_plan.writes == [:plan, :tasks]

    code = Flows.get_flow(ctx.board, "code")
    assert Enum.find(code.nodes, &(&1.key == "branch")).writes == [:branch]
    assert Enum.find(code.nodes, &(&1.key == "post")).writes == [:ai_result]
    assert Enum.find(code.nodes, &(&1.key == "merge")).writes == [:pr_url]

    # The atom-vs-string regression: a sparse library map must compare EQUAL to the dense
    # embedded struct, or customized?/1 flags every default flow as customized forever.
    for key <- ~w(spec plan code) do
      refute Flows.customized?(Flows.get_flow!(ctx.board, key)), "#{key} must not read as customized"
    end
  end
end
