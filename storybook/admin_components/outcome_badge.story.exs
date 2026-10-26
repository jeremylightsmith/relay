defmodule Storybook.AdminComponents.OutcomeBadge do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.AdminComponents.outcome_badge/1
  def render_source, do: :function

  # RE463: a payment attempt's outcome in the `/admin/users` side panel's payment history
  # (and the Renewals log).
  def variations do
    for outcome <- Hamaca.Billing.attempt_outcomes() do
      %Variation{id: outcome, description: "Outcome #{outcome}", attributes: %{outcome: outcome}}
    end
  end
end
