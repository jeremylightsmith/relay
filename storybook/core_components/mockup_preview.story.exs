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
        description:
          "RE374 — the drawer's Mockups entry: an 80px square thumbnail tile (a scaled, sandboxed iframe); the caption is its tooltip and aria-label, and the tile opens the viewer in a new tab.",
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
      },
      %VariationGroup{
        id: :wrapping_row,
        description: "Several mockups — the drawer lays the tiles out in a wrapping row (flex flex-wrap gap-2).",
        template: """
        <div class="flex flex-wrap gap-2 max-w-64" psb-code-hidden>
          <.psb-variation-group />
        </div>
        """,
        variations:
          for {caption, n} <- Enum.with_index(["Empty state", "Board", "Drawer", "Settings", "Mobile"], 1) do
            %Variation{
              id: :"tile_#{n}",
              attributes: %{
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
