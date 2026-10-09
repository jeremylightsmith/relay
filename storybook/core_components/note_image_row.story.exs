defmodule Storybook.Components.CoreComponents.NoteImageRow do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.note_image_row/1
  def render_source, do: :function

  # RE427 — a posted note's images. Each thumbnail's src is `/attachments/<id>`, so the story's
  # fixed ids draw the empty `bg-base-200` box a missing image leaves: the 108px height, the
  # border and the 240px cap are what this page shows.
  defp image(id, filename), do: %Schemas.Attachment{id: id, filename: filename}

  def variations do
    [
      %Variation{
        id: :two_images,
        description: "Two images under a note: a wrapping row of 108px-tall thumbnails, each patching to the viewer.",
        attributes: %{
          id: "note-image-row-story-two",
          images: [image("story-overflow", "overflow.png"), image("story-phone", "phone.png")],
          image_href: &"/storybook/core_components/note_image_row?image=#{&1}"
        }
      },
      %Variation{
        id: :single_wide,
        description: "One wide screenshot: kept at 108px tall and capped at 240px wide (object-cover).",
        attributes: %{
          id: "note-image-row-story-wide",
          images: [image("story-wide", "full-board-screenshot.png")],
          image_href: &"/storybook/core_components/note_image_row?image=#{&1}"
        }
      }
    ]
  end
end
