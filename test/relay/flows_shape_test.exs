defmodule Relay.FlowsShapeTest do
  use ExUnit.Case, async: true

  alias Relay.Flows.Shape
  alias Schemas.Stage

  # The live RE board's columns, as plain structs (no DB), ordered by `Stage.order_stages/1` —
  # the same table as `flows_neighbours_test.exs`.
  @re_stages [
    {1, "Suggested", 1, nil, :queue},
    {2, "Someday maybe", 2, nil, :queue},
    {3, "Backlog", 3, nil, :queue},
    {4, "Ready for Design", 4, nil, :queue},
    {5, "Design", 5, nil, :planning},
    {51, "Design:Review", 13, 5, :review},
    {6, "Ready for Spec", 6, nil, :queue},
    {7, "Spec", 7, nil, :planning},
    {71, "Spec:Review", 14, 7, :review},
    {72, "Spec:Done", 15, 7, :done},
    {8, "Plan", 8, nil, :planning},
    {81, "Plan:Done", 16, 8, :done},
    {9, "Code", 9, nil, :work},
    {91, "Code:Done", 17, 9, :done},
    {10, "Deploy", 10, nil, :work},
    {11, "Review", 11, nil, :review},
    {12, "Done", 12, nil, :done}
  ]

  # `{id, name, type}` main stages in board order, plus `{id, name, type, parent_id}` substages.
  defp board(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn
      {{id, name, type}, position} ->
        %Stage{id: id, name: name, position: position, parent_id: nil, type: type}

      {{id, name, type, parent}, position} ->
        %Stage{id: id, name: name, position: 100 + position, parent_id: parent, type: type}
    end)
    |> Enum.shuffle()
    |> Stage.order_stages()
  end

  defp flow(key, stage_id, enabled \\ true), do: %{key: key, stage_id: stage_id, enabled: enabled}

  defp only_problem(stages, flows) do
    assert [problem] = Shape.problems(stages, flows)
    problem
  end

  defp labels(problem), do: Enum.map(problem.fixes, & &1.label)

  # Scenario 2.
  defp triage_board, do: board([{1, "Triage", :work}, {2, "Backlog", :queue}])
  defp triage_problem, do: only_problem(triage_board(), [flow("triage", 1)])

  # Scenario 6 (and 11 with a trailing Done).
  defp code_deploy_board(extra \\ []),
    do: board([{1, "Backlog", :queue}, {2, "Code", :work}, {3, "Deploy", :work}, {4, "Review", :review}] ++ extra)

  defp deploy_problem(stages \\ code_deploy_board()), do: only_problem(stages, [flow("code", 2), flow("deploy", 3)])

  @deploy_what "Flow **deploy** pulls from Code, which is flow **code**'s working stage."
  @deploy_why "Deploy would pull cards out of Code while the code flow is still working them. " <>
                "Each upstream card needs somewhere to rest when it's finished before the next flow can take it."

  test "1. the healthy RE board has no problems" do
    stages =
      @re_stages
      |> Enum.map(fn {id, name, position, parent_id, type} ->
        %Stage{id: id, name: name, position: position, parent_id: parent_id, type: type}
      end)
      |> Enum.shuffle()
      |> Stage.order_stages()

    flows = [flow("design", 5), flow("spec", 7), flow("plan", 8), flow("code", 9), flow("deploy", 10)]

    assert Shape.problems(stages, flows) == []
  end

  test "2. a flow on the first column has no upstream" do
    problem = triage_problem()

    assert %{flow_key: "triage", stage_id: 1, enabled: true, kind: :no_upstream} = problem
    assert problem.what == "Triage is the first column on the board, so there is no column before it."

    assert problem.why ==
             "A flow only ever pulls work from the column before its stage — Relay never pushes work in. " <>
               "With nothing before Triage, no card can ever reach the flow."

    assert problem.fixes == [
             %{
               action: :insert_queue_stage,
               before_stage_id: 1,
               name: "Ready for Triage",
               label: "Insert a queue stage before Triage"
             }
           ]
  end

  test "3. a flow on the only stage is :no_upstream, never :no_downstream" do
    assert %{kind: :no_upstream} = only_problem(board([{1, "Solo", :work}]), [flow("solo", 1)])
  end

  test "4. a Review substage right before the stage is :upstream_review" do
    stages =
      board([{1, "Backlog", :queue}, {2, "Spec", :planning}, {21, "Spec:Review", :review, 2}, {3, "Plan", :planning}])

    problem = only_problem(stages, [flow("plan", 3)])

    assert problem.kind == :upstream_review

    assert problem.what ==
             "The column before Plan is **Spec · Review** — a place where a human approves, not a place where cards rest."

    assert problem.why ==
             "Approving a card in Spec · Review moves it straight into Plan. That is a push: it skips Plan's WIP " <>
               "limit and the scheduler, so Plan can end up with more work than it's allowed."

    assert labels(problem) == ["Turn on Spec · Done", "Insert a queue stage between Spec and Plan"]
    assert [%{action: :enable_lane, stage_id: 2, lane: :done}, second] = problem.fixes
    assert %{action: :insert_queue_stage, before_stage_id: 3, name: "Ready for Plan"} = second
  end

  test "5. a Review main stage right before the stage is :upstream_review" do
    stages = board([{1, "Backlog", :queue}, {2, "Review", :review}, {3, "Retro", :work}, {4, "Done", :done}])
    problem = only_problem(stages, [flow("retro", 3)])

    assert problem.kind == :upstream_review
    assert problem.what =~ "**Review**"
    assert labels(problem) == ["Turn on Review · Done", "Insert a queue stage between Review and Retro"]
    assert [%{action: :enable_lane, stage_id: 2, lane: :done} | _] = problem.fixes
  end

  test "6. a flow pulling from another flow's working stage is :upstream_working" do
    problem = deploy_problem()

    assert %{flow_key: "deploy", kind: :upstream_working} = problem
    assert problem.what == @deploy_what
    assert problem.why == @deploy_why
    assert labels(problem) == ["Turn on Code · Done", "Insert a queue stage between Code and Deploy"]

    assert [
             %{action: :enable_lane, stage_id: 2, lane: :done},
             %{action: :insert_queue_stage, before_stage_id: 3, name: "Ready for Deploy"}
           ] = problem.fixes
  end

  test "7. a disabled upstream flow is still named" do
    problem = only_problem(code_deploy_board(), [flow("code", 2, false), flow("deploy", 3)])

    assert %{flow_key: "deploy", kind: :upstream_working} = problem
    assert problem.what == @deploy_what
  end

  test "8. a human work stage right before the stage is :upstream_working with no flow named" do
    stages = board([{1, "Backlog", :queue}, {2, "Build", :work}, {3, "Ship", :work}, {4, "Done", :done}])
    problem = only_problem(stages, [flow("ship", 3)])

    assert problem.kind == :upstream_working
    assert problem.what == "Flow **ship** pulls from Build, a stage where people are still working."

    assert problem.why ==
             "Ship would pull cards out of Build while they are still being worked. " <>
               "Each upstream card needs somewhere to rest when it's finished before the next flow can take it."
  end

  test "9. a flow on the last column has no downstream" do
    stages = board([{1, "Backlog", :queue}, {2, "Spec", :planning}, {22, "Spec:Done", :done, 2}, {3, "Retro", :work}])
    problem = only_problem(stages, [flow("retro", 3)])

    assert problem.kind == :no_downstream
    assert problem.what == "Retro is the last column on the board, so there is no column after it."

    assert problem.why ==
             "When a run finishes it moves the card to the next column. " <>
               "With nothing after Retro, finished cards would have nowhere to go."

    assert problem.fixes == [
             %{action: :enable_lane, stage_id: 3, lane: :done, label: "Turn on Retro · Done"},
             %{action: :add_stage_after, stage_id: 3, label: "Add a stage after Retro"}
           ]
  end

  test "10. the last main stage with its own Done substage has somewhere to land" do
    stages = board([{1, "Backlog", :queue}, {2, "Code", :work}, {21, "Code:Done", :done, 2}])
    assert Shape.problems(stages, [flow("code", 2)]) == []
  end

  test "11. columns are the two either side, marking self and the offender" do
    assert deploy_problem(code_deploy_board([{5, "Done", :done}])).columns == [
             %{stage_id: 1, name: "Backlog", type: :queue, mark: nil},
             %{stage_id: 2, name: "Code", type: :work, mark: :offending},
             %{stage_id: 3, name: "Deploy", type: :work, mark: :self},
             %{stage_id: 4, name: "Review", type: :review, mark: nil},
             %{stage_id: 5, name: "Done", type: :done, mark: nil}
           ]

    assert triage_problem().columns == [
             %{stage_id: 1, name: "Triage", type: :work, mark: :self},
             %{stage_id: 2, name: "Backlog", type: :queue, mark: nil}
           ]
  end

  test "11b. a substage column carries its display name" do
    stages =
      board([{1, "Backlog", :queue}, {2, "Spec", :planning}, {21, "Spec:Review", :review, 2}, {3, "Plan", :planning}])

    assert %{stage_id: 21, name: "Spec · Review", type: :review, mark: :offending} in only_problem(stages, [
             flow("plan", 3)
           ]).columns
  end

  test "12. kinds/0 and fix_actions/0 are the closed sets every problem draws from" do
    assert Shape.kinds() == [:no_upstream, :upstream_review, :upstream_working, :no_downstream]
    assert Shape.fix_actions() == [:enable_lane, :insert_queue_stage, :add_stage_after]

    problems = [
      triage_problem(),
      only_problem(board([{1, "Solo", :work}]), [flow("solo", 1)]),
      only_problem(
        board([{1, "Backlog", :queue}, {2, "Spec", :planning}, {21, "Spec:Review", :review, 2}, {3, "Plan", :planning}]),
        [flow("plan", 3)]
      ),
      only_problem(board([{1, "Backlog", :queue}, {2, "Review", :review}, {3, "Retro", :work}]), [flow("retro", 3)]),
      deploy_problem(),
      only_problem(board([{1, "Backlog", :queue}, {2, "Build", :work}, {3, "Ship", :work}]), [flow("ship", 3)]),
      only_problem(board([{1, "Backlog", :queue}, {3, "Retro", :work}]), [flow("retro", 3)])
    ]

    for problem <- problems do
      assert problem.kind in Shape.kinds()
      for fix <- problem.fixes, do: assert(fix.action in Shape.fix_actions())
    end

    assert problems |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort() == Enum.sort(Shape.kinds())
  end

  test "13. wire/1 is the string-keyed JSON projection" do
    assert Shape.wire(deploy_problem()) == %{
             "flow_key" => "deploy",
             "kind" => "upstream_working",
             "what" => @deploy_what,
             "why" => @deploy_why,
             "fixes" => [
               %{"action" => "enable_lane", "label" => "Turn on Code · Done"},
               %{"action" => "insert_queue_stage", "label" => "Insert a queue stage between Code and Deploy"}
             ],
             "columns" => [
               %{"stage_id" => 1, "name" => "Backlog", "type" => "queue", "mark" => nil},
               %{"stage_id" => 2, "name" => "Code", "type" => "work", "mark" => "offending"},
               %{"stage_id" => 3, "name" => "Deploy", "type" => "work", "mark" => "self"},
               %{"stage_id" => 4, "name" => "Review", "type" => "review", "mark" => nil}
             ]
           }

    assert Shape.wire(nil) == nil
  end

  test "14. paused_detail/1 names the paused flow" do
    assert Shape.paused_detail(deploy_problem()) ==
             "Flow **deploy** is paused: no new runs start until the board is fixed. Runs already going will finish and land."
  end

  test "15. a disabled flow on a broken shape is still reported, enabled: false" do
    assert %{kind: :no_upstream, enabled: false} = only_problem(triage_board(), [flow("triage", 1, false)])
  end

  test "a flow whose stage is not on the board contributes nothing" do
    assert Shape.problems(triage_board(), [flow("ghost", 999)]) == []
  end

  test "problems come back in the order the flows were passed" do
    stages = board([{1, "Triage", :work}, {2, "Backlog", :queue}, {3, "Retro", :work}])
    assert Enum.map(Shape.problems(stages, [flow("retro", 3), flow("triage", 1)]), & &1.flow_key) == ["retro", "triage"]
  end
end
