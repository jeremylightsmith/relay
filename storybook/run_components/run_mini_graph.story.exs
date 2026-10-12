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
      },
      # RE440: the card mockup's state 1 — the fan_out's segment split per branch, mid flight.
      %Variation{
        id: :fan_out_region,
        attributes: %{
          path: ["sync", "implement", "fan_reviews", "review_join", "fix_findings", "precommit"],
          run: %{
            flow_key: "code",
            current_node: "fan_reviews",
            branch_bars: %{"fan_reviews" => [:succeeded, :running, :running]}
          },
          task_progress: nil
        }
      }
    ]
  end
end
