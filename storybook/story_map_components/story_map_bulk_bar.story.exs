defmodule Storybook.StoryMapComponents.StoryMapBulkBar do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.StoryMapComponents.story_map_bulk_bar/1
  def render_source, do: :function

  # The bar floats at the bottom of a `relative` parent (`#story-map-viewport` in the app), so
  # each variation gets one tall enough to show the bar and, when open, the menu above it.
  def template do
    """
    <div class="relative h-72 w-full bg-base-200 rounded-box">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :closed,
        description: "RE502 — 5 cards selected, no menu open",
        attributes: %{count: 5, open_menu: nil}
      },
      %Variation{
        id: :menu_open,
        description:
          "RE502 — the Release menu open: its button turns primary and the menu anchors above the bar's left edge",
        attributes: %{count: 5, open_menu: :release},
        slots: [
          """
          <:menu>
            <div class="bg-base-100 border border-base-300 rounded-box shadow-lg w-56 p-3 text-xs text-base-content/70">
              The bulk menu renders here.
            </div>
          </:menu>
          """
        ]
      }
    ]
  end
end
