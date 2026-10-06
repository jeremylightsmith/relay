defmodule Storybook.Components.CoreComponents.SegmentedControl do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.segmented_control/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :text,
        description:
          "RE393 — the embedded review card's tabs: equal segments on a base-200 track, the " <>
            "active one lifted onto base-100.",
        attributes: %{id: "segmented-control-story-text", aria_label: "Card sections"},
        slots: [
          ~s(<:option id="segmented-story-detail" label="Detail" active />),
          ~s(<:option id="segmented-story-run" label="Run" />),
          ~s(<:option id="segmented-story-activity" label="Activity" />)
        ]
      },
      %Variation{
        id: :icon,
        description: "The icon variant (the mockup viewer's render width): each label is the aria-label.",
        attributes: %{id: "segmented-control-story-icon", variant: :icon, aria_label: "Render width"},
        slots: [
          ~s(<:option id="segmented-story-phone" icon="hero-device-phone-mobile" label="Phone width" active />),
          ~s(<:option id="segmented-story-desktop" icon="hero-computer-desktop" label="Desktop, fit to width" />)
        ]
      }
    ]
  end
end
