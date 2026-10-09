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
      }
    ]
  end
end
