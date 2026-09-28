defmodule Storybook.StoryMapComponents.StoryMapToolbar do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.StoryMapComponents.story_map_toolbar/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :map_zoom, attributes: %{zoom: :map, hide_steps: false}},
      %Variation{id: :compact_zoom, attributes: %{zoom: :compact, hide_steps: false}},
      %Variation{id: :full_zoom, attributes: %{zoom: :full, hide_steps: false}},
      %Variation{id: :hiding_steps, attributes: %{zoom: :compact, hide_steps: true}}
    ]
  end
end
