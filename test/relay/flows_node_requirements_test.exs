defmodule Relay.FlowsNodeRequirementsTest do
  @moduledoc """
  What a flow's graph NAMES (RLY-182) — pure, no executor knowledge. This function lives in
  Flows precisely because it needs none: whether anyone HAS these is Runs' question, and
  Flows may not depend on Runs (boundary cycle).
  """
  use Relay.DataCase, async: true

  alias Relay.Flows
  alias Schemas.Flow

  defp flow(nodes), do: %Flow{nodes: Enum.map(nodes, &struct!(Flow.Node, &1))}

  test "agent fields are collected, deduped and sorted" do
    result =
      [
        %{key: "b", type: :agent, agent: "spec-reviewer"},
        %{key: "a", type: :agent, agent: "plan-implementer"},
        %{key: "c", type: :agent, agent: "spec-reviewer"},
        %{key: "d", type: :gate, run: "mix precommit"}
      ]
      |> flow()
      |> Flows.node_requirements()

    assert result.agents == ["plan-implementer", "spec-reviewer"]
  end

  test "the leading slash-command token of an agent node's run is a skill" do
    result =
      [
        %{key: "p", type: :agent, run: "/write-plan {ref}"},
        %{key: "b", type: :agent, run: "/brainstorm {ref}"}
      ]
      |> flow()
      |> Flows.node_requirements()

    assert result.skills == ["brainstorm", "write-plan"]
  end

  test "a shell or gate node's run is a shell command, never a skill" do
    result =
      [
        %{key: "g", type: :gate, run: "mix precommit"},
        %{key: "s", type: :shell, run: "/usr/bin/env true"}
      ]
      |> flow()
      |> Flows.node_requirements()

    assert result.skills == []
    assert result.agents == []
  end

  test "an agent node whose run is not a slash command contributes no skill" do
    result = flow([%{key: "i", type: :agent, agent: "plan-implementer", run: "Do the task."}])

    assert Flows.node_requirements(result).skills == []
  end

  test "the shipped Code flow yields its eight agent names", %{} do
    board = insert(:board)
    :ok = Flows.seed_default_flows!(board)
    result = board |> Flows.get_flow!("code") |> Flows.node_requirements()

    assert result.agents == [
             "acceptance-tester",
             "final-fixer",
             "final-reviewer",
             "plan-implementer",
             "quality-reviewer",
             "rebaser",
             "smoke-tester",
             "spec-reviewer"
           ]
  end

  test "the shipped Plan flow yields the write-plan skill" do
    board = insert(:board)
    :ok = Flows.seed_default_flows!(board)

    assert %{skills: ["write-plan"], agents: []} =
             board |> Flows.get_flow!("plan") |> Flows.node_requirements()
  end
end
