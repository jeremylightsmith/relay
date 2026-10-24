defmodule Storybook.AdminComponents.PlanBadge do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.AdminComponents.plan_badge/1
  def render_source, do: :function

  # RE463, card mockup "Billing screens — pricing section, Billing page, past-due and read-only
  # board, superadmin, iOS status", §4: the `/admin/users` Plan column.
  def variations do
    for plan <- Relay.Billing.admin_plans() do
      %Variation{id: plan, description: "Plan #{plan}", attributes: %{plan: plan}}
    end
  end
end
