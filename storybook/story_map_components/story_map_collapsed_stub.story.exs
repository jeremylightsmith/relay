defmodule Storybook.StoryMapComponents.StoryMapCollapsedStub do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.StoryMapComponents.story_map_collapsed_stub/1
  def render_source, do: :function

  defp checkout, do: %Schemas.StoryActivity{id: 7, board_id: 1, name: "Checkout", position: 1}

  def variations do
    [
      %Variation{
        id: :collapsed,
        description: "Clicking expands it again.",
        attributes: %{activity: checkout(), index: 0, count: 3, focusing: false}
      },
      %Variation{
        id: :while_focusing,
        description: "In Focus mode the same click MOVES the focus here instead.",
        attributes: %{activity: checkout(), index: 0, count: 12, focusing: true}
      },
      %Variation{
        id: :empty,
        description: "An activity holding no cards still shows its badge.",
        attributes: %{activity: checkout(), index: 0, count: 0, focusing: false}
      },
      %Variation{
        id: :read_only,
        description: "On an archived board the stub is not a RE261 reorder source or target.",
        attributes: %{
          activity: checkout(),
          index: 0,
          count: 3,
          focusing: false,
          read_only: true
        }
      }
    ]
  end
end
