defmodule Storybook.Components.CoreComponents.MediaPlaceholder do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.media_placeholder/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :file_name,
        description:
          "RE390 — an AI Result screenshot the browser can't fetch (an agent-local path): a dashed " <>
            "80px tile captioned with its file name. Not a link.",
        attributes: %{id: "media-placeholder-story-file", caption: "12-review.png"}
      },
      %Variation{
        id: :long_caption,
        description: "A long caption breaks anywhere and stays inside the square.",
        attributes: %{
          id: "media-placeholder-story-long",
          caption: "Users/me/src/relay/tmp/smoke/12-state3a-review-after-approve.png"
        }
      }
    ]
  end
end
