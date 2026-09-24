defmodule Storybook.FlowGraph do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowGraphComponents.flow_graph/1
  def render_source, do: :function

  defp code_flow do
    Enum.find(Relay.Flows.DefaultLibrary.all(), &(&1.key == "code"))
  end

  def variations do
    code = code_flow()
    park_nodes = [%{key: "a", type: :agent, run: "x"}, %{key: "g", type: :gate, run: "mix test"}]

    park_edges = [
      %{from: "start", to: "a", on: nil},
      %{from: "a", to: "g", on: :succeeded},
      %{from: "a", to: "needs_input", on: :failed},
      %{from: "g", to: "done", on: :succeeded}
    ]

    # RE333: the shape the old two-column layout could not draw.
    branchy_nodes = [
      %{key: "triage", type: :gate, run: "mix triage"},
      %{key: "fix", type: :agent, agent: "plan-implementer", model: "sonnet", effort: "high"},
      %{key: "ship", type: :shell, run: "mix release"},
      %{key: "write_docs", type: :agent, model: "haiku", effort: "low"},
      %{key: "publish", type: :shell, run: "mix docs.publish"},
      %{key: "escalate", type: :human, run: "ask a maintainer"}
    ]

    branchy_edges = [
      %{from: "start", to: "triage", on: nil},
      %{from: "triage", to: "fix", on: :succeeded},
      %{from: "triage", to: "write_docs", on: :failed},
      %{from: "fix", to: "ship", on: :succeeded},
      %{from: "fix", to: "fix", on: :failed, max_loops: 2},
      %{from: "ship", to: "done", on: :succeeded},
      %{from: "write_docs", to: "publish", on: :succeeded},
      %{from: "publish", to: "done", on: :succeeded},
      %{from: "write_docs", to: "escalate", on: :failed}
    ]

    [
      %Variation{
        id: :default_code_flow,
        description:
          "The shipped Code flow, laid out by dagre_ex: ranks run top to bottom, every rework " <>
            "loop is routed as its own orthogonal path, and every edge label sits in room " <>
            "reserved for it, clear of nodes and of other labels. Failed edges are dashed and " <>
            "carry max-N loop badges. Every node that can park on a human (an edge into " <>
            "needs_input) carries a warning pause badge at its top-right corner instead of a " <>
            "drawn edge. Agent nodes stack their binding — subagent · model · effort (e.g. " <>
            "plan-implementer · sonnet · high); a generic agent node with no subagent reads just " <>
            "model · effort.",
        attributes: %{
          nodes: code.nodes,
          edges: code.edges,
          layout: RelayWeb.FlowLayout.layout(code.nodes, code.edges),
          lands_on: "Review",
          interactive?: false
        }
      },
      %Variation{
        id: :park_badge,
        description:
          "A node that can park for human input carries a warning pause badge on its top-right " <>
            "corner (hover: \"Can park for human input\"). Here the agent can park; the gate " <>
            "cannot. The needs_input edges themselves are not drawn.",
        attributes: %{
          nodes: park_nodes,
          edges: park_edges,
          layout: RelayWeb.FlowLayout.layout(park_nodes, park_edges),
          lands_on: "Review",
          interactive?: false
        }
      },
      %Variation{
        id: :branching,
        description:
          "A branchy flow the old two-column layout could not draw (RE333): the triage gate " <>
            "diverges into two branches that never rejoin, `fix` self-loops on failure, and " <>
            "there is more than one terminal — `ship` and `publish` each reach done by their " <>
            "own path, while `escalate` is a dead end. Where several edges meet one side of a " <>
            "node they get their own ports (RE340): triage's two out-edges leave from separate " <>
            "points on the diamond's lower faces, and the two exit edges land apart on done.",
        attributes: %{
          nodes: branchy_nodes,
          edges: branchy_edges,
          layout: RelayWeb.FlowLayout.layout(branchy_nodes, branchy_edges),
          lands_on: "Review",
          interactive?: false
        }
      },
      %Variation{
        id: :minimal,
        description: "A one-node flow — start → work → done.",
        attributes: %{
          nodes: [%{key: "work", type: :agent, run: "go", model: "sonnet", effort: "high"}],
          edges: [%{from: "start", to: "work", on: nil}, %{from: "work", to: "done", on: :succeeded}],
          layout:
            RelayWeb.FlowLayout.layout(
              [%{key: "work", type: :agent, run: "go"}],
              [%{from: "start", to: "work", on: nil}, %{from: "work", to: "done", on: :succeeded}]
            ),
          lands_on: "Done",
          interactive?: false
        }
      }
    ]
  end
end
