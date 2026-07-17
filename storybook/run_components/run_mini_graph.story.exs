defmodule Storybook.RunComponents.RunMiniGraph do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_mini_graph/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :mid_flight,
        attributes: %{
          path: ["branch", "implement", "spec_review", "quality_review"],
          run: %{flow_key: "code", current_node: "implement"},
          task_progress: %{done: 1, total: 4}
        }
      },
      %Variation{
        id: :reentry,
        attributes: %{
          path: ["branch", "implement", "spec_review", "quality_review"],
          run: %{flow_key: "code", current_node: "spec_review"},
          task_progress: nil
        }
      }
    ]
  end
end
