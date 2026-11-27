defmodule Storybook.Components.CoreComponents.ReportedPlaceholder do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.CoreComponents.reported_placeholder/1
  def render_source, do: :function

  # What the reporter sees in place of an item they reported (RE510, card mockup "Public board —
  # ⋯ Report…", state 1).
  def variations do
    [
      %Variation{
        id: :idea,
        description: "A reported public-board idea",
        attributes: %{id: "story-reported-idea", kind: :idea, target_id: 5}
      },
      %Variation{
        id: :comment,
        description: "A reported comment in the card drawer",
        attributes: %{id: "story-reported-comment", kind: :comment, target_id: 9}
      }
    ]
  end
end
