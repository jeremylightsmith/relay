defmodule Storybook.Components.CoreComponents.ImageAttachButton do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.image_attach_button/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :default,
        description:
          "RE427 — the 📎: a label wrapping a hidden multiple file input. Hidden below the drawer: " <>
            "breakpoint (phones are view-only) — widen the canvas to see it.",
        attributes: %{
          id: "image-attach-button-story",
          upload: Storybook.Components.CoreComponents.ImageAttachBox.upload()
        }
      }
    ]
  end
end
