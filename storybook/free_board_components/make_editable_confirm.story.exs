defmodule Storybook.FreeBoardComponents.MakeEditableConfirm do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.FreeBoardComponents.make_editable_confirm/1
  def render_source, do: :function

  # A daisyUI `modal-open` (a fixed overlay), so the variation renders in its own iframe.
  def container, do: {:iframe, style: "height: 360px;"}

  # RE471: the confirm a read-only board's banner and Billing open before switching.
  def variations do
    [
      %Variation{
        id: :default,
        description: "Make a read-only board the editable one",
        attributes: %{board_id: 3, board_name: "Acme Checkout", editable_name: "Hamaca Engineering"}
      }
    ]
  end
end
