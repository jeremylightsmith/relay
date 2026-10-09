defmodule Storybook.Components.CoreComponents.NoteOriginTag do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.note_origin_tag/1
  def render_source, do: :function

  # RE428 — where an image note came from, after the <time> in the Notes author row. An ordinary
  # note (origin nil) renders no tag at all.
  def variations do
    [
      %Variation{
        id: :from_answer,
        description: "Images attached while answering question 2 of the needs-input stepper.",
        attributes: %{id: "note-origin-tag-story-answer", origin: :answer, question: 2}
      },
      %Variation{
        id: :from_rejection,
        description: "Images attached to Request changes.",
        attributes: %{id: "note-origin-tag-story-rejection", origin: :rejection}
      }
    ]
  end
end
