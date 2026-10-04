defmodule Storybook.Components.CoreComponents.CardReviewPanel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.card_review_panel/1
  def render_source, do: :function

  defp gate, do: %{approve_label: "Approve → Done", reject_target_name: "Code", can_reject: true}
  defp reject_form(note \\ ""), do: Phoenix.Component.to_form(%{"note" => note}, as: :reject)

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
