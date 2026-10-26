defmodule Storybook.AdminComponents.UserTabs do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.AdminComponents.user_tabs/1
  def render_source, do: :function

  # RE462 / RE463, card mockup "Billing screens — pricing section, Billing page, past-due and read-only
  # board, superadmin, iOS status", §4: the `/admin/users` tab bar.
  def variations do
    [
      %Variation{id: :users, description: "On /admin/users", attributes: %{active: :users}},
      %Variation{id: :usage, description: "On /admin/users/usage (RE475)", attributes: %{active: :usage}},
      %Variation{
        id: :promo_codes,
        description: "On /admin/users/promo-codes",
        attributes: %{active: :promo_codes}
      },
      %Variation{
        id: :renewals,
        description: "On /admin/users/renewals",
        attributes: %{active: :renewals}
      }
    ]
  end
end
