defmodule Storybook.Components.CoreComponents.CardMockupsSection do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.card_mockups_section/1
  def render_source, do: :function

  # A real mockup is an /attachments/<id> HTML page; the tiles load whatever `src` the section
  # derives from each id, so these ids just need to be distinct.
  defp mockups do
    [
      %{id: "story-empty", caption: "A — empty state"},
      %{id: "story-panes", caption: "B — two panes"},
      %{id: "story-error", caption: "C — error"},
      %{id: "story-uncaptioned", caption: nil}
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
          mockups: mockups(),
          mockup_href: &"/storybook/core_components/card_mockups_section?m=#{&1}"
        }
      },
      %Variation{
        id: :viewer_sheet,
        description:
          "The mockup viewer's left sheet: the current tile is ringed and aria-current, the others " <>
            "dimmed, then \"Viewing … · n of m\" and the ← → / Esc key hint.",
        attributes: %{
          id: "card-mockups-story-sheet",
          tile_id: "card-mockups-story-sheet-mockup",
          mockups: mockups(),
          mockup_href: &"/storybook/core_components/card_mockups_section?m=#{&1}",
          current: "story-panes",
          replace: true
        }
      }
    ]
  end
end
