defmodule Storybook.Components.CoreComponents.MockupViewerHeader do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.mockup_viewer_header/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :mockup,
        description:
          "RE392 — the desktop viewer's header over the mockup: the noun, the caption, n of m and " <>
            "the key hint. A label, never a switcher.",
        attributes: %{
          id: "mockup-viewer-header-story-mockup",
          caption: "B — two panes",
          index: 2,
          total: 3
        }
      },
      %Variation{
        id: :screenshot,
        description: "Screenshots mode: the noun swaps.",
        attributes: %{
          id: "mockup-viewer-header-story-screenshot",
          noun: "Screenshot",
          caption: "Review drawer",
          index: 2,
          total: 2
        }
      },
      %Variation{
        id: :long_caption,
        description: "A long caption truncates; the noun, the count and the key hint keep their width.",
        attributes: %{
          id: "mockup-viewer-header-story-long",
          caption:
            "A — the empty state of the review drawer with the gate panel collapsed, the timeline " <>
              "folded and every attachment tile showing its placeholder",
          index: 1,
          total: 3
        },
        template: """
        <div class="w-[420px]"><.psb-variation/></div>
        """
      }
    ]
  end
end
