defmodule Storybook.Components.CoreComponents.MockupPreview do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.mockup_preview/1
  def render_source, do: :function

  # A real mockup is an /attachments/<id> HTML page; any same-origin path shows the frame here.
  def variations do
    [
      %Variation{
        id: :captioned,
        description: "RE370 — the drawer's Mockups entry: caption, Open full size (new tab), sandboxed iframe.",
        attributes: %{
          id: "mockup-preview-story-captioned",
          src: "/images/logo_light_128.png",
          view_href: "/storybook/core_components/mockup_preview",
          caption: "Empty state"
        }
      },
      %Variation{
        id: :uncaptioned,
        description: "No caption — falls back to \"Mockup\".",
        attributes: %{
          id: "mockup-preview-story-uncaptioned",
          src: "/images/logo_light_128.png",
          view_href: "/storybook/core_components/mockup_preview"
        }
      }
    ]
  end
end
