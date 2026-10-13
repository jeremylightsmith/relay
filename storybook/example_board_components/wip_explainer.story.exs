defmodule Storybook.ExampleBoardComponents.WipExplainer do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.ExampleBoardComponents.wip_explainer/1
  def render_source, do: :function

  # RE444: the How / Why / Here box, from the Tiny Dungeon (three-brain) example.
  def variations do
    [
      %Variation{
        id: :three_brain,
        description: "Plan is at its limit (wip 2/2)",
        attributes: %{chip: "wip 2/2", wip: Relay.Examples.get("three-brain").wip}
      }
    ]
  end
end
