defmodule Storybook.Components.CoreComponents.ImageAttachHint do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.image_attach_hint/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :hint,
        description: "RE427 — the limits hint from drawer: up; \"Attach images from the web app.\" below it.",
        attributes: %{id: "image-attach-hint-story-hint"}
      },
      %Variation{
        id: :errors,
        description: "Refused images, in order, above the hint.",
        attributes: %{
          id: "image-attach-hint-story-errors",
          errors: [
            "recording.mov isn’t an image (PNG, JPEG, WebP or GIF).",
            "huge.png is 9.1 MB — the limit is 5 MB."
          ]
        }
      },
      %Variation{
        id: :embed,
        description: "The native embed: only \"Attach images from the web app.\", at every width.",
        attributes: %{id: "image-attach-hint-story-embed", enabled: false}
      }
    ]
  end
end
