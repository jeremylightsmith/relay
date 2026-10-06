defmodule Storybook.Components.CoreComponents.MockupViewerZoom do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.mockup_viewer_zoom/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :fit,
        description:
          "RE393 — the embedded mockup viewer's zoom control, over the bottom-right of an HTML mockup. " <>
            "The server renders Fit with − disabled; in the viewer the .MockupRenderWidth hook steps it " <>
            "through 150% · 200% · 300% · 400% and toggles the disabled ends.",
        attributes: %{id: "mockup-viewer-zoom-story"}
      }
    ]
  end
end
