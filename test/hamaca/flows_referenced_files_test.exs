defmodule Hamaca.FlowsReferencedFilesTest do
  @moduledoc """
  RE447: `Hamaca.Flows.referenced_files/1` — the `.claude/` agent and skill files a set of flows
  NAMES, one entry per distinct file with its repo path(s) and the `{flow, node}` pairs naming it.
  Pure, beside `node_requirements/1`.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Boards
  alias Hamaca.Boards.Templates
  alias Hamaca.Flows
  alias Schemas.Flow

  defp flow(key, nodes), do: %Flow{key: key, nodes: Enum.map(nodes, &struct!(Flow.Node, &1))}

  # Scenario 12
  test "one entry per distinct agent or skill, in first-appearance order, with paths and used_by" do
    code =
      flow("code", [
        %{key: "implement", type: :agent, agent: "plan-implementer"},
        %{key: "review", type: :agent, agent: "spec-reviewer", run: "/write-plan RE1"},
        %{key: "gate", type: :gate, run: "/not-a-skill"}
      ])

    plan = flow("plan", [%{key: "p", type: :agent, agent: "plan-implementer"}])

    assert Flows.referenced_files([code, plan]) == [
             %{
               kind: :agent,
               name: "plan-implementer",
               paths: [".claude/agents/plan-implementer.md"],
               used_by: [%{flow: "code", node: "implement"}, %{flow: "plan", node: "p"}]
             },
             %{
               kind: :agent,
               name: "spec-reviewer",
               paths: [".claude/agents/spec-reviewer.md"],
               used_by: [%{flow: "code", node: "review"}]
             },
             %{
               kind: :skill,
               name: "write-plan",
               paths: [".claude/skills/write-plan/SKILL.md", ".claude/commands/write-plan.md"],
               used_by: [%{flow: "code", node: "review"}]
             }
           ]
  end

  # Scenario 13
  test "an inline-only flow, and no flows at all, reference no files" do
    inline =
      flow("inline", [
        %{key: "draft", type: :agent, run: "Write the spec for {ref}."},
        %{key: "build", type: :agent, run: "Implement it."},
        %{key: "check", type: :gate, run: "mix precommit"}
      ])

    assert Flows.referenced_files(inline) == []
    assert Flows.referenced_files([]) == []
  end

  # Scenario 14
  test "every template board's flows are inline, so they reference no files" do
    user = insert(:user)

    for slug <- Templates.slugs() do
      {:ok, board} = Boards.create_board(user, %{name: "T", template: slug})
      assert Flows.list_flows(board) != []
      assert Flows.referenced_files(Flows.list_flows(board)) == [], "template #{slug} names repo files"
    end
  end
end
