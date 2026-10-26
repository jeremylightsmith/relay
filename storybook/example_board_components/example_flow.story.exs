defmodule Storybook.ExampleBoardComponents.ExampleFlow do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.ExampleBoardComponents.example_flow/1
  def render_source, do: :function

  # RE444: the three-brain template's planning flow as the example board shows it, with its
  # Tiny Dungeon blurb and default-selected node. The neighbour stages are what
  # `Hamaca.Flows.list_flows/1` would fill on the seeded board.
  def variations do
    template = Enum.find(Hamaca.Boards.templates(), &(&1.slug == "three-brain"))
    example = Hamaca.Examples.get("three-brain")
    flow = Enum.find(template.flows, &(&1.key == "three-brain-plan"))
    %{blurb: blurb, selected: selected} = example.flows[flow.key]

    [
      %Variation{
        id: :three_brain_plan,
        description: "Three planners, a judge and a mockup; gpt_plan selected",
        attributes: %{
          flow:
            Map.merge(flow, %{
              pulls_from_stage: %{name: "Backlog"},
              stage: %{name: "Plan"},
              lands_on_stage: %{name: "Review"}
            }),
          blurb: blurb,
          selected: selected,
          llm: %{default: "Claude Opus", red: MapSet.new()},
          agents: %{
            "Claude Opus" => %{name: "Claude Opus", harness: "Claude Code"},
            "GPT" => %{name: "GPT", harness: "Codex"},
            "Gemini" => %{name: "Gemini", harness: "Gemini CLI"}
          }
        }
      }
    ]
  end
end
