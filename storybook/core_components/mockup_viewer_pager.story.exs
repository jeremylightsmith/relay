defmodule Storybook.Components.CoreComponents.MockupViewerPager do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.mockup_viewer_pager/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :first,
        description:
          "RE393 — the embedded mockup viewer's pager row under the frame: ‹ dots n of m ›. " <>
            "The first item: ‹ is disabled.",
        attributes: %{id: "mockup-viewer-pager-story-first", index: 1, total: 2}
      },
      %Variation{
        id: :middle,
        description: "A middle item: both chevrons are live, the current dot is solid.",
        attributes: %{id: "mockup-viewer-pager-story-middle", index: 2, total: 3}
      },
      %Variation{
        id: :last,
        description: "The last screenshot: › is disabled and the labels name the noun.",
        attributes: %{id: "mockup-viewer-pager-story-last", index: 3, total: 3, noun: "Screenshot"}
      }
    ]
  end
end
