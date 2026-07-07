defmodule Storybook.Components.CoreComponents.BoardCard do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.board_card/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :title_and_ref,
        attributes: %{id: "story-card-1", ref: "RLY-1", title: "Wire up Google sign-in"}
      },
      %Variation{
        id: :with_tag,
        attributes: %{
          id: "story-card-2",
          ref: "RLY-2",
          title: "Design the card composer",
          tag: "design"
        }
      }
    ]
  end
end
