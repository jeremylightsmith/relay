defmodule Storybook.Components.CoreComponents.MockupPreview do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.mockup_preview/1
  def render_source, do: :function

  # A real mockup is an /attachments/<id> HTML page; any same-origin path shows the miniature here.
  def variations do
    [
      %Variation{
        id: :captioned,
        description:
          "RE374 — the drawer's Mockups tile: an 80px square live miniature (sandboxed iframe, " <>
            "scaled from 1280px) that opens the framed viewer in a new tab. Hover for the caption.",
        attributes: %{
          id: "mockup-preview-story-captioned",
          src: "/images/logo_light_128.png",
          view_href: "/storybook/core_components/mockup_preview",
          caption: "Empty state"
        }
      },
      %Variation{
        id: :uncaptioned,
        description: "No caption — the tooltip and aria-label fall back to \"Mockup\".",
        attributes: %{
          id: "mockup-preview-story-uncaptioned",
          src: "/images/logo_light_128.png",
          view_href: "/storybook/core_components/mockup_preview"
        }
      },
      %VariationGroup{
        id: :wrapping_row,
        description:
          "Several mockups, as the drawer lays them out: side by side in a flex-wrap row (gap-2) " <>
            "that wraps when the drawer narrows.",
        template: """
        <div class="flex max-w-60 flex-wrap gap-2" psb-code-hidden>
          <.psb-variation-group />
        </div>
        """,
        variations:
          for {caption, index} <- Enum.with_index(["Empty state", "Loaded", "Error", "Mobile", nil]) do
            %Variation{
              id: :"tile_#{index}",
              attributes: %{
                id: "mockup-preview-story-row-#{index}",
                src: "/images/logo_light_128.png",
                view_href: "/storybook/core_components/mockup_preview",
                caption: caption
              }
            }
          end
      }
    ]
  end
end
