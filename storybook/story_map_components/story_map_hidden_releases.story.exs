defmodule Storybook.StoryMapComponents.StoryMapHiddenReleases do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.StoryMapComponents.story_map_hidden_releases/1
  def render_source, do: :function

  defp mvp, do: %Schemas.Release{id: 100, board_id: 1, name: "MVP", position: 1}
  defp fast_follow, do: %Schemas.Release{id: 200, board_id: 1, name: "Fast follow", position: 2}

  def variations do
    [
      %Variation{
        id: :one_hidden_release,
        description: "Hide complete took one complete release off the grid. Show turns Hide complete off.",
        attributes: %{releases: [mvp()], row: 1}
      },
      %Variation{
        id: :two_hidden_releases,
        description: "Several hidden releases fold into the same one line, named in lane order.",
        attributes: %{releases: [mvp(), fast_follow()], row: 1}
      }
    ]
  end
end
