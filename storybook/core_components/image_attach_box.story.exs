defmodule Storybook.Components.CoreComponents.ImageAttachBox do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Phoenix.LiveView.UploadConfig
  alias Phoenix.LiveView.UploadEntry

  def function, do: &RelayWeb.CoreComponents.image_attach_box/1

  def imports,
    do: [{RelayWeb.CoreComponents, icon: 1, image_attach_button: 1, image_attach_hint: 1}, {__MODULE__, upload: 0}]

  def render_source, do: :function

  # RE427 — the shared image control, as the Notes composer renders it: the box (drop target +
  # paste hook), the composer row in its slot (textarea, 📎, Add note) and the hint line under it.
  # The UploadConfig is a hand-built stand-in for `@uploads.note_images`; its entries are the
  # thumbnails "in flight" (their live_img_preview stays blank without a real file).
  @upload_ref "phx-story-note-images"

  def upload(entries \\ []) do
    %UploadConfig{
      name: :note_images,
      ref: @upload_ref,
      accept: Enum.join(Schemas.Attachment.image_types(), ","),
      max_entries: Schemas.Comment.max_images(),
      max_file_size: Schemas.Attachment.max_bytes(),
      auto_upload?: true,
      entries: entries
    }
  end

  defp uploading(name) do
    %UploadEntry{
      ref: "story-#{name}",
      upload_ref: @upload_ref,
      upload_config: :note_images,
      client_name: name,
      progress: 40
    }
  end

  defp pending do
    [
      %{id: "story-board", filename: "board.png", src: "/images/logo_light_128.png"},
      %{id: "story-drawer", filename: "drawer.png", src: "/images/logo_dark_128.png"}
    ]
  end

  defp row(text \\ "") do
    """
    <textarea rows="2" placeholder="What you did, what you found, what’s left…" class="min-w-0 flex-1 resize-none border-none bg-transparent p-0 text-[12.5px] leading-[18px] text-base-content focus:outline-none">#{text}</textarea>
    <.image_attach_button id="image-attach-box-story-attach" upload={upload()} />
    <button type="button" class="btn h-[27px] min-h-0 shrink-0 rounded-md border border-base-300 bg-base-100 px-3 text-[11.5px] font-semibold text-base-content/80">Add note</button>
    """
  end

  defp with_hint(errors) do
    """
    <div class="max-w-[640px]">
      <.psb-variation/>
      <.image_attach_hint id="image-attach-box-story-hint" errors={#{inspect(errors)}} />
    </div>
    """
  end

  @over_cap "That’s 6 — the most one note can carry. Post this one and start another."

  def variations do
    [
      %Variation{
        id: :empty,
        description: "Nothing attached: the composer row with the 📎 (hidden below the drawer: breakpoint).",
        attributes: %{id: "image-attach-box-story-empty", upload: upload()},
        slots: [row()],
        template: with_hint([])
      },
      %Variation{
        id: :uploading,
        description: "One image uploaded, one still in flight under the Uploading… overlay (its ✕ cancels it).",
        attributes: %{
          id: "image-attach-box-story-uploading",
          upload: upload([uploading("timeline.png")]),
          pending: Enum.take(pending(), 1)
        },
        slots: [row("Here’s the before/after")],
        template: with_hint([])
      },
      %Variation{
        id: :with_thumbnails,
        description: "Two uploaded images as 156×108 thumbnails under the row, each with a ✕ (Remove).",
        attributes: %{id: "image-attach-box-story-thumbs", upload: upload(), pending: pending()},
        slots: [row("see screenshots")],
        template: with_hint([])
      },
      %Variation{
        id: :over_cap,
        description: "More than six chosen: the first six attach, the rest are refused; the text stays.",
        attributes: %{id: "image-attach-box-story-over-cap", upload: upload(), pending: pending()},
        slots: [row("before/after")],
        template: with_hint([@over_cap])
      },
      %Variation{
        id: :wrong_type,
        description: "A non-image is refused by name.",
        attributes: %{id: "image-attach-box-story-wrong-type", upload: upload()},
        slots: [row()],
        template: with_hint(["recording.mov isn’t an image (PNG, JPEG, WebP or GIF)."])
      },
      %Variation{
        id: :too_large,
        description: "A file over 5 MB is refused with its size.",
        attributes: %{id: "image-attach-box-story-too-large", upload: upload()},
        slots: [row()],
        template: with_hint(["huge.png is 9.1 MB — the limit is 5 MB."])
      },
      %Variation{
        id: :drag_over,
        description:
          "A file dragged over the box: LiveView adds phx-drop-target-active (forced here), which " <>
            "draws the dashed primary border and the Drop to attach overlay.",
        attributes: %{id: "image-attach-box-story-drag-over", upload: upload(), class: "phx-drop-target-active"},
        slots: [row("Here’s the before/after")],
        template: with_hint([])
      }
    ]
  end
end
