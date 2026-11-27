defmodule Storybook.Components.CoreComponents.ReportModal do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.CoreComponents.report_modal/1
  def render_source, do: :function

  # The report modal (RE510, card mockup "Public board — ⋯ Report…", states 2 and 3).
  defp form(reason), do: Phoenix.Component.to_form(%{"reason" => reason, "note" => ""}, as: :report)

  @idea %{kind: :card, id: 1, quote: "Dark mode for the widget"}

  def variations do
    [
      %Variation{
        id: :form_empty,
        description: "Reporting an idea — no reason chosen yet, Send disabled",
        attributes: %{target: @idea, step: :form, form: form(""), sla_hours: 24}
      },
      %Variation{
        id: :form_reason_chosen,
        description: "A reason chosen — its row highlights and Send enables",
        attributes: %{target: @idea, step: :form, form: form("harassment"), sla_hours: 24}
      },
      %Variation{
        id: :comment,
        description: "Reporting a member's comment",
        attributes: %{
          target: %{kind: :comment, id: 2, quote: "You are all idiots"},
          step: :form,
          form: form(""),
          sla_hours: 24
        }
      },
      %Variation{
        id: :sent,
        description: "The confirmation after sending",
        attributes: %{target: @idea, step: :sent, form: form("spam"), sla_hours: 24}
      }
    ]
  end
end
