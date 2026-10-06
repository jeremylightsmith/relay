defmodule Storybook.Components.CoreComponents.MobileNavBar do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.mobile_nav_bar/1
  def imports, do: [{RelayWeb.CoreComponents, icon: 1}]
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :review_card,
        description:
          "RE393 — the embedded review card's bar: ‹ Board pops the native stack (history.back() " <>
            "in a browser), the ref is the centered 17/600 title, ⋯ on the right.",
        attributes: %{
          id: "mobile-nav-bar-story-review",
          title: "RL9001",
          back_label: "Board",
          back_bridge: true
        },
        slots: [
          """
          <:actions>
            <button type="button" class="flex size-11 items-center justify-center text-primary" aria-label="Card actions">
              <.icon name="hero-ellipsis-horizontal-circle" class="size-[26px]" />
            </button>
          </:actions>
          """
        ]
      },
      %Variation{
        id: :patch_back,
        description: "A same-LiveView back: a patch link (the mockup viewer back to its card).",
        attributes: %{
          id: "mobile-nav-bar-story-patch",
          title: "Empty state — a long caption that truncates in the middle of the bar",
          back_label: "Card",
          back_patch: "/storybook/core_components/mobile_nav_bar"
        }
      },
      %Variation{
        id: :default_label,
        description: "No back label (the card was opened without `back=`): it reads Back.",
        attributes: %{id: "mobile-nav-bar-story-default", title: "RL9001", back_bridge: true}
      }
    ]
  end
end
