defmodule RelayWeb.AdminComponents do
  @moduledoc """
  Shared pieces of the superadmin pages under `/admin`.

    * `user_tabs/1` — the `Users | Promo codes | Renewals` tab bar (RE462, RE463; card mockup
      "Billing screens — pricing section, Billing page, past-due and read-only board, superadmin,
      iOS status", §4) on `/admin/users` (`RelayWeb.Admin.UsersLive`), `/admin/users/promo-codes`
      (`RelayWeb.Admin.PromoCodesLive`) and `/admin/users/renewals`
      (`RelayWeb.Admin.RenewalsLive`). The pages share the `:admin` live_session, so a tab
      switch is a live navigation.
    * `plan_badge/1` — a user's admin plan (`Relay.Billing.admin_plans/0`) as a daisyUI badge on
      `/admin/users` (RE463, same mockup, §4).
    * `outcome_badge/1` — a payment attempt's outcome (`Relay.Billing.attempt_outcomes/0`) as a
      daisyUI badge, in the `/admin/users` side panel's payment history and on the Renewals tab
      (RE463).
  """
  use RelayWeb, :html

  @doc "The `Users | Promo codes | Renewals` tab bar; `active` names the current tab."
  attr :active, :atom, required: true, values: [:users, :promo_codes, :renewals]
  attr :id, :string, default: "admin-user-tabs"

  def user_tabs(assigns) do
    assigns = assign(assigns, :tabs, user_tab_list())

    ~H"""
    <div id={@id} role="tablist" class="tabs tabs-box tabs-sm">
      <.link
        :for={tab <- @tabs}
        id={tab.id}
        navigate={tab.path}
        role="tab"
        class={["tab", tab.key == @active && "tab-active"]}
      >
        {tab.label}
      </.link>
    </div>
    """
  end

  # The ONE list of the `/admin/users` tabs.
  defp user_tab_list do
    [
      %{key: :users, id: "admin-tab-users", label: "Users", path: ~p"/admin/users"},
      %{key: :promo_codes, id: "admin-tab-promo-codes", label: "Promo codes", path: ~p"/admin/users/promo-codes"},
      %{key: :renewals, id: "admin-tab-renewals", label: "Renewals", path: ~p"/admin/users/renewals"}
    ]
  end

  @doc """
  A user's admin plan (`Relay.Billing.admin_plans/0`) as a small daisyUI badge: trial primary,
  active success, past due error, cancelled outline, comped neutral, paused warning, member only
  ghost.
  """
  attr :plan, :atom, required: true, values: Relay.Billing.admin_plans()
  attr :id, :string, default: nil

  def plan_badge(assigns) do
    {class, label} = plan_badge_style(assigns.plan)
    assigns = assign(assigns, class: class, label: label)

    ~H"""
    <span id={@id} class={["badge badge-sm", @class]}>{@label}</span>
    """
  end

  # The ONE class / label map of the admin plans.
  defp plan_badge_style(:trial), do: {"badge-soft badge-primary", "trial"}
  defp plan_badge_style(:active), do: {"badge-soft badge-success", "active"}
  defp plan_badge_style(:past_due), do: {"badge-soft badge-error", "past due"}
  defp plan_badge_style(:cancelled), do: {"badge-outline", "cancelled"}
  defp plan_badge_style(:comped), do: {"badge-soft badge-neutral", "comped"}
  defp plan_badge_style(:paused), do: {"badge-soft badge-warning", "paused"}
  defp plan_badge_style(:member_only), do: {"badge-ghost", "member only"}

  @doc """
  A payment attempt's outcome (`Relay.Billing.attempt_outcomes/0`) as a small daisyUI badge:
  paid success, declined error, unknown warning, not charged ghost.
  """
  attr :outcome, :atom, required: true, values: Relay.Billing.attempt_outcomes()
  attr :id, :string, default: nil

  def outcome_badge(assigns) do
    {class, label} = outcome_badge_style(assigns.outcome)
    assigns = assign(assigns, class: class, label: label)

    ~H"""
    <span id={@id} class={["badge badge-sm", @class]}>{@label}</span>
    """
  end

  # The ONE class / label map of the attempt outcomes.
  defp outcome_badge_style(:paid), do: {"badge-soft badge-success", "paid"}
  defp outcome_badge_style(:declined), do: {"badge-soft badge-error", "declined"}
  defp outcome_badge_style(:unknown), do: {"badge-soft badge-warning", "unknown"}
  defp outcome_badge_style(:not_charged), do: {"badge-ghost", "not charged"}
end
