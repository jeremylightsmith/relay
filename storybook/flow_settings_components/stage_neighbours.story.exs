defmodule Storybook.FlowSettingsComponents.StageNeighbours do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowSettingsComponents.stage_neighbours/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :full,
        description: "Both neighbours present — a sub-lane renders as \"Plan · Done\"",
        attributes: %{id: "code-neighbours", pulls_from: "Plan · Done", works_in: "Code", lands_on: "Review"}
      },
      %Variation{
        id: :missing_end,
        description: "The board's first stage — the missing end reads none",
        attributes: %{id: "spec-neighbours", pulls_from: nil, works_in: "Spec", lands_on: "Spec · Review"}
      },
      %Variation{
        id: :offending,
        description: "RE432 — the pickup breaks the shape rule: PULLS FROM renders dashed amber",
        attributes: %{
          id: "plan-neighbours",
          pulls_from: "Spec · Review",
          works_in: "Plan",
          lands_on: "Plan · Done",
          offending: :pulls_from
        }
      }
    ]
  end
end
