defmodule RelayWeb.AdminComponents do
  @moduledoc """
  Shared pieces of the superadmin pages under `/admin`.

    * `user_tabs/1` — the `Users | Promo codes` tab bar (RE462, card mockup "Billing screens —
      pricing section, Billing page, past-due and read-only board, superadmin, iOS status", §4)
      on `/admin/users` (`RelayWeb.Admin.UsersLive`) and `/admin/users/promo-codes`
      (`RelayWeb.Admin.PromoCodesLive`). Both pages share the `:admin` live_session, so a tab
      switch is a live navigation.
  """
  use RelayWeb, :html

  @doc "The `Users | Promo codes` tab bar; `active` names the current tab."
  attr :active, :atom, required: true, values: [:users, :promo_codes]
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

  # The ONE list of the `/admin/users` tabs (RE463 adds Renewals here).
  defp user_tab_list do
    [
      %{key: :users, id: "admin-tab-users", label: "Users", path: ~p"/admin/users"},
      %{key: :promo_codes, id: "admin-tab-promo-codes", label: "Promo codes", path: ~p"/admin/users/promo-codes"}
    ]
  end
end
