defmodule Storybook.StoryMapComponents.InlineNameInput do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.StoryMapComponents.inline_name_input/1
  def render_source, do: :function

  # `hook: nil` renders the input inert: the InlineNameInput hook lives in the app bundle and
  # only makes sense inside BoardLive, where a real draft is open.
  def variations do
    [
      %Variation{
        id: :empty,
        attributes: %{
          id: "inline-name-input-empty",
          hook: nil,
          placeholder: "Activity name… ↵",
          submit: "story_map_draft_submit",
          change: "story_map_draft_change",
          cancel: "story_map_draft_cancel"
        }
      },
      %Variation{
        id: :filled,
        attributes: %{
          id: "inline-name-input-filled",
          hook: nil,
          value: "Onboard & access",
          placeholder: "Activity name… ↵",
          submit: "story_map_draft_submit",
          change: "story_map_draft_change",
          cancel: "story_map_draft_cancel"
        }
      }
    ]
  end
end
