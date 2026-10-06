defmodule Storybook.Components.CoreComponents.CardMockupsSection do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.card_mockups_section/1
  def render_source, do: :function

  # `RelayWeb.CardMedia` items. A real HTML mockup is an /attachments/<id> page; any same-origin
  # path shows the miniature here.
  defp mockups do
    for {key, caption} <- [
          {"story-empty", "A — empty state"},
          {"story-panes", "B — two panes"},
          {"story-error", "C — error"},
          {"story-uncaptioned", nil}
        ] do
      %{key: key, src: "/images/logo_light_128.png", caption: caption, kind: :html}
    end
  end

  defp screenshots do
    [
      %{key: 1, src: "/images/logo_light_128.png", caption: "Board", kind: :image},
      %{key: nil, src: nil, caption: "12-review.png", kind: :placeholder},
      %{key: 2, src: "/images/logo_dark_128.png", caption: nil, kind: :image}
    ]
  end

  def variations do
    [
      %Variation{
        id: :drawer,
        description: "RE380 — the card drawer's Mockups section: no current tile, a gap-2 row.",
        attributes: %{
          id: "card-mockups-story-drawer",
          tile_id: "card-mockups-story-drawer-mockup",
          items: mockups(),
          item_href: &"/storybook/core_components/card_mockups_section?m=#{&1}"
        }
      },
      %Variation{
        id: :viewer_sheet,
        description:
          "The mockup viewer's left sheet: the current tile is ringed and aria-current, the others " <>
            "dimmed; the section ends at the tiles.",
        attributes: %{
          id: "card-mockups-story-sheet",
          tile_id: "card-mockups-story-sheet-mockup",
          items: mockups(),
          item_href: &"/storybook/core_components/card_mockups_section?m=#{&1}",
          current: "story-panes",
          replace: true
        }
      },
      %Variation{
        id: :screenshots,
        description:
          "RE390 — the drawer's AI Result Screenshots through the same section: image tiles cropped " <>
            "to the top, and a dashed placeholder for a path the browser can't fetch. The drawer " <>
            "draws its own \"Screenshots\" label, so show_label is false there.",
        attributes: %{
          id: "card-mockups-story-screenshots",
          tile_id: "card-mockups-story-screenshot",
          items: screenshots(),
          item_href: &"/storybook/core_components/card_mockups_section?screenshot=#{&1}",
          label: "Screenshots",
          noun: "Screenshot"
        }
      }
    ]
  end
end
