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

    [
      %Variation{
        id: :default_code_flow,
        description: "The shipped Code flow: 14 nodes, serpentine, dashed failed edges, max-N loop badges.",
        attributes: %{
          nodes: code.nodes,
          edges: code.edges,
          layout: RelayWeb.FlowLayout.layout(code.nodes, code.edges),
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
