defmodule HamacaWeb.AdminComponents do
  @moduledoc """
  Shared pieces of the superadmin pages under `/admin`.

    * `user_tabs/1` — the `Users | Usage | Promo codes | Renewals` tab bar (RE462, RE463,
      RE475; card mockup "Billing screens — pricing section, Billing page, past-due and read-only
      board, superadmin, iOS status", §4) on `/admin/users` (`HamacaWeb.Admin.UsersLive`),
      `/admin/users/usage` (`HamacaWeb.Admin.UsageLive`), `/admin/users/promo-codes`
      (`HamacaWeb.Admin.PromoCodesLive`) and `/admin/users/renewals`
      (`HamacaWeb.Admin.RenewalsLive`). The pages share the `:admin` live_session, so a tab
      switch is a live navigation.
    * `usage_strip/1` — a user's last days as a row of cells, one per `Hamaca.Usage.day_state()`:
      visited blue (`primary`), agents ran violet (`secondary`), both split, neither `base-300`
      (RE475; card mockups "Usage tab — people (blue) + their agents (violet)" at `:sm` and
      "User panel — visits, time, agent runs, shipped" at `:lg`).
    * `stacked_bars/1` — the Usage tab's daily chart: one CSS-flex bar per day, people (blue)
      under their agents (violet), scaled to the busiest day (RE475, the Usage tab mockup).
    * `plan_badge/1` — a user's admin plan (`Hamaca.Billing.admin_plans/0`) as a daisyUI badge on
      `/admin/users` (RE463, same mockup, §4).
    * `outcome_badge/1` — a payment attempt's outcome (`Hamaca.Billing.attempt_outcomes/0`) as a
      daisyUI badge, in the `/admin/users` side panel's payment history and on the Renewals tab
      (RE463).
  """
  use HamacaWeb, :html

  @doc "The `Users | Usage | Promo codes | Renewals` tab bar; `active` names the current tab."
  attr :active, :atom, required: true, values: [:users, :usage, :promo_codes, :renewals]
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
      %{key: :usage, id: "admin-tab-usage", label: "Usage", path: ~p"/admin/users/usage"},
      %{key: :promo_codes, id: "admin-tab-promo-codes", label: "Promo codes", path: ~p"/admin/users/promo-codes"},
      %{key: :renewals, id: "admin-tab-renewals", label: "Renewals", path: ~p"/admin/users/renewals"}
    ]
  end

  @doc """
  A row of day cells, one per `Hamaca.Usage.day_state()` in `days` (oldest first), each carrying
  `data-state`. `:sm` is the Usage table's compact strip, `:lg` the user panel's.
  """
  attr :days, :list, required: true
  attr :size, :atom, values: [:sm, :lg], default: :sm
  attr :id, :string, default: nil

  def usage_strip(assigns) do
    {row, cell} = usage_strip_size(assigns.size)
    assigns = assign(assigns, row_class: row, cell_class: cell)

    ~H"""
    <div id={@id} class={@row_class}>
      <%= for day <- @days do %>
        <span
          :if={day == :both}
          data-state="both"
          class={[@cell_class, "overflow-hidden flex flex-col"]}
        >
          <span class="flex-1 bg-primary"></span>
          <span class="flex-1 bg-secondary"></span>
        </span>
        <span :if={day != :both} data-state={day} class={[@cell_class, usage_day_fill(day)]}></span>
      <% end %>
    </div>
    """
  end

  # The ONE size map of the strip: `{row classes, cell classes}`.
  defp usage_strip_size(:sm), do: {"flex gap-[3px] items-center", "h-4 w-2.5 rounded-sm"}
  defp usage_strip_size(:lg), do: {"flex gap-1.5 items-center", "h-10 flex-1 rounded-md"}

  # The ONE fill of a single-color day state (`:both` is split, above).
  defp usage_day_fill(:none), do: "bg-base-300"
  defp usage_day_fill(:human), do: "bg-primary"
  defp usage_day_fill(:agent), do: "bg-secondary"

  @doc """
  A daily stacked bar chart: one bar per `%{date, people, agents}` in `series`, agents (violet)
  above people (blue), each segment's height a whole percent of the busiest day's total (at least
  1, so an all-zero series is all 0%). Each bar is `"\#{id}-bar-<ISO date>"` with `data-people` /
  `data-agents`.
  """
  attr :series, :list, required: true
  attr :id, :string, required: true

  def stacked_bars(assigns) do
    peak = assigns.series |> Enum.map(&(&1.people + &1.agents)) |> Enum.max(fn -> 0 end) |> max(1)
    assigns = assign(assigns, :peak, peak)

    ~H"""
    <div id={"#{@id}-bars"} class="mt-4 flex h-40 items-end gap-1 sm:gap-1.5 border-b border-base-300">
      <div
        :for={day <- @series}
        id={"#{@id}-bar-#{Date.to_iso8601(day.date)}"}
        data-people={day.people}
        data-agents={day.agents}
        class="flex-1 flex flex-col justify-end h-full gap-px"
      >
        <div class="bg-secondary rounded-t-sm" style={"height:#{bar_percent(day.agents, @peak)}%"}>
        </div>
        <div class="bg-primary" style={"height:#{bar_percent(day.people, @peak)}%"}></div>
      </div>
    </div>
    """
  end

  defp bar_percent(count, peak), do: round(count / peak * 100)

  @doc """
  A user's admin plan (`Hamaca.Billing.admin_plans/0`) as a small daisyUI badge: free primary,
  active success, past due error, cancelled outline, comped neutral, paused warning, member only
  ghost.
  """
  attr :plan, :atom, required: true, values: Hamaca.Billing.admin_plans()
  attr :id, :string, default: nil

  def plan_badge(assigns) do
    {class, label} = plan_badge_style(assigns.plan)
    assigns = assign(assigns, class: class, label: label)

    ~H"""
    <span id={@id} class={["badge badge-sm", @class]}>{@label}</span>
    """
  end

  # The ONE class / label map of the admin plans.
  defp plan_badge_style(:free), do: {"badge-soft badge-primary", "free"}
  defp plan_badge_style(:active), do: {"badge-soft badge-success", "active"}
  defp plan_badge_style(:past_due), do: {"badge-soft badge-error", "past due"}
  defp plan_badge_style(:cancelled), do: {"badge-outline", "cancelled"}
  defp plan_badge_style(:comped), do: {"badge-soft badge-neutral", "comped"}
  defp plan_badge_style(:paused), do: {"badge-soft badge-warning", "paused"}
  defp plan_badge_style(:member_only), do: {"badge-ghost", "member only"}

  @doc """
  A payment attempt's outcome (`Hamaca.Billing.attempt_outcomes/0`) as a small daisyUI badge:
  paid success, declined error, unknown warning, not charged ghost.
  """
  attr :outcome, :atom, required: true, values: Hamaca.Billing.attempt_outcomes()
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
