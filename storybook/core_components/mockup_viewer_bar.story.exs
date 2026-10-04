defmodule Storybook.Components.CoreComponents.MockupViewerBar do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.mockup_viewer_bar/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :middle,
        description:
          "RE380 — the phone viewer's one top bar: ← back to the card, the caption over n / m, " <>
            "and ‹ › to switch mockups.",
        attributes: %{
          id: "mockup-viewer-bar-story-middle",
          caption: "B — two panes",
          index: 2,
          total: 3,
          back_patch: "/storybook/core_components/mockup_viewer_bar"
        }
      },
      %Variation{
        id: :first,
        description: "The first mockup: ‹ is disabled.",
        attributes: %{
          id: "mockup-viewer-bar-story-first",
          caption: "A — empty state",
          index: 1,
          total: 3,
          back_patch: "/storybook/core_components/mockup_viewer_bar"
        }
      },
      %Variation{
        id: :last,
        description: "The last mockup: › is disabled.",
        attributes: %{
          id: "mockup-viewer-bar-story-last",
          caption: "C — error",
          index: 3,
          total: 3,
          back_patch: "/storybook/core_components/mockup_viewer_bar"
        }
      }
    ]
  end
end
