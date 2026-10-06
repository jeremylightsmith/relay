defmodule Storybook.Components.CoreComponents.NotificationToast do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.notification_toast/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :needs_input,
        description: "Needs input, on the board in view",
        attributes: %{
          kind: :needs_input,
          card_ref: "RE391",
          title: "Question from the AI",
          card_title: "update landing page"
        }
      },
      %Variation{
        id: :in_review,
        description: "Ready for review, on the board in view",
        attributes: %{
          kind: :in_review,
          card_ref: "RE388",
          title: "Ready for your review",
          card_title: "Star a board from the boards page"
        }
      },
      %Variation{
        id: :other_board,
        description: "A card on another board names that board",
        attributes: %{
          kind: :in_review,
          card_ref: "MK42",
          title: "Ready for your review",
          card_title: "Pricing table copy pass for the October launch",
          board_name: "Marketing site"
        }
      }
    ]
  end
end
