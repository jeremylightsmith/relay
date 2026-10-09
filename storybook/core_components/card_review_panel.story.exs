defmodule Storybook.Components.CoreComponents.CardReviewPanel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.card_review_panel/1
  def render_source, do: :function

  defp gate, do: %{approve_label: "Approve → Done", reject_target_name: "Code", can_reject: true}
  defp reject_form(note \\ ""), do: Phoenix.Component.to_form(%{"note" => note}, as: :reject)

  # RE428 — a hand-built stand-in for `@uploads.reject_images` (as image_attach_box's story does);
  # its entries are the thumbnails still in flight.
  @upload_ref "phx-story-reject-images"

  defp upload(entries) do
    %Phoenix.LiveView.UploadConfig{
      name: :reject_images,
      ref: @upload_ref,
      accept: Enum.join(Schemas.Attachment.image_types(), ","),
      max_entries: Schemas.Comment.max_images(),
      max_file_size: Schemas.Attachment.max_bytes(),
      auto_upload?: true,
      entries: entries
    }
  end

  defp uploading(name) do
    %Phoenix.LiveView.UploadEntry{
      ref: "story-#{name}",
      upload_ref: @upload_ref,
      upload_config: :reject_images,
      client_name: name,
      progress: 40
    }
  end

  # The panel's children carry fixed ids (review-approve, review-reject-form, …) by contract, so
  # these variations share them on this one page — like needs_input_panel's story does.
  def variations do
    [
      %Variation{
        id: :drawer,
        description: "RE380 — the drawer's review panel, extracted verbatim: Approve names the next stage.",
        attributes: %{review_gate: gate(), reject_open: false, reject_form: reject_form()}
      },
      %Variation{
        id: :drawer_reject_open,
        description: "The drawer's in-place reject note: 3 rows, the long returns-to hint.",
        attributes: %{review_gate: gate(), reject_open: true, reject_form: reject_form()}
      },
      %Variation{
        id: :drawer_reject_with_images,
        description:
          "RE428 — Request changes with images: the note sits in the shared image control, each " <>
            "uploaded image is a thumbnail and a link line in the note, one more is still uploading " <>
            "(Reject waits for it), and the Attach images bar sits under the note.",
        attributes: %{
          review_gate: gate(),
          reject_open: true,
          reject_form:
            reject_form(
              "The empty state is too tall on mobile — it pushes the composer off-screen:\n" <>
                "![empty-mobile.png](https://relayboard.fly.dev/attachments/story-empty-mobile)\n" <>
                "![Uploading phone.png…]()"
            ),
          upload: upload([uploading("phone.png")]),
          images_pending: [%{id: "story-empty-mobile", filename: "empty-mobile.png", src: "/images/logo_light_128.png"}]
        }
      },
      %Variation{
        id: :compact,
        description: "The mockup viewer's left sheet at rest: Approve says just \"Approve\".",
        attributes: %{review_gate: gate(), reject_open: false, reject_form: reject_form(), compact: true}
      },
      %Variation{
        id: :compact_reject_open,
        description:
          "The sheet with the note open while switching mockups: 8 rows, + Quote the current " <>
            "mockup's caption, and the note-stays-put reminder.",
        attributes: %{
          review_gate: gate(),
          reject_open: true,
          reject_form: reject_form("The empty state needs a call to action."),
          compact: true,
          quote_caption: "B — two panes"
        }
      }
    ]
  end
end
