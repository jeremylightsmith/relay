defmodule Storybook.Components.CoreComponents.BoardViewTabs do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.board_view_tabs/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :board_active, attributes: %{board_slug: "my-board", active: :board}},
      %Variation{id: :story_map_active, attributes: %{board_slug: "my-board", active: :story_map}}
    ]
  end
end
