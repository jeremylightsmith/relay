defmodule RelayWeb.Admin.RenewalsLive do
  @moduledoc """
  The superadmin's **Renewals** tab at `/admin/users/renewals` (RE463, ADR 0012): every payment
  attempt across accounts, newest first (`Relay.Billing.renewal_log/1`, capped at
  `Relay.Billing.renewal_log_limit/0`) — date, user, period, amount, the promo code the attempt
  recorded, outcome and Stripe PaymentIntent id — filterable by outcome with `?outcome=` (one of
  `Relay.Billing.attempt_outcomes/0`; anything else means all).

  Read-only on purpose: the billing clock is automatic, so there is no "run billing" button. The
  rows are a stream, re-streamed with `reset: true` on each filter patch. Shares the
  `Users | Usage | Promo codes | Renewals` tab bar (`RelayWeb.AdminComponents.user_tabs/1`). Gated by the
  `:admin` live_session.
  """
  use RelayWeb, :live_view

  import RelayWeb.AdminComponents, only: [user_tabs: 1, outcome_badge: 1]

  alias Relay.Billing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Renewals")
     |> assign(:outcomes, Billing.attempt_outcomes())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    outcome = outcome_param(params["outcome"])
    rows = Billing.renewal_log(outcome)

    {:noreply,
     socket
     |> assign(:outcome, outcome)
     |> assign(:empty?, rows == [])
     |> stream(:renewals, rows, dom_id: &"renewal-#{&1.id}", reset: true)}
  end

  # Matches the param against the outcome names — never turns user input into an atom.
  defp outcome_param(value) when is_binary(value),
    do: Enum.find(Billing.attempt_outcomes(), &(Atom.to_string(&1) == value))

  defp outcome_param(_value), do: nil

  defp filter_label(:not_charged), do: "Not charged"
  defp filter_label(outcome), do: outcome |> Atom.to_string() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div id="admin-renewals-page" class="mx-auto max-w-5xl px-4 py-8">
        <.link
          navigate={~p"/admin"}
          id="admin-back"
          class="text-sm text-base-content/65 link link-hover"
        >
          ← Admin
        </.link>
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <h1 class="text-2xl font-semibold">Users</h1>
          <span class="flex-1"></span>
          <.user_tabs active={:renewals} />
        </div>
        <p class="mt-1 text-sm text-base-content/65">
          Every payment attempt across accounts, newest first. The billing clock runs on its own.
        </p>

        <div id="renewals-filter" role="tablist" class="tabs tabs-border tabs-sm mt-6">
          <.link
            id="renewals-filter-all"
            patch={~p"/admin/users/renewals"}
            role="tab"
            class={["tab", is_nil(@outcome) && "tab-active"]}
          >
            All
          </.link>
          <.link
            :for={outcome <- @outcomes}
            id={"renewals-filter-#{outcome}"}
            patch={~p"/admin/users/renewals?#{[outcome: outcome]}"}
            role="tab"
            class={["tab", @outcome == outcome && "tab-active"]}
          >
            {filter_label(outcome)}
          </.link>
        </div>

        <div class="mt-3 overflow-x-auto rounded-box border border-base-200">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Date</th>
                <th>User</th>
                <th>Period</th>
                <th class="text-right">Amount</th>
                <th>Code</th>
                <th>Outcome</th>
                <th>PaymentIntent</th>
              </tr>
            </thead>
            <tbody id="admin-renewals" phx-update="stream">
              <tr :for={{dom_id, row} <- @streams.renewals} id={dom_id}>
                <td class="font-mono text-xs whitespace-nowrap">{Date.to_iso8601(row.date)}</td>
                <td>
                  <div :if={row.user.name} class="font-medium">{row.user.name}</div>
                  <div class="text-xs text-base-content/65">{row.user.email}</div>
                </td>
                <td class="font-mono text-xs whitespace-nowrap">
                  {Date.to_iso8601(row.period_start)} – {Date.to_iso8601(row.period_end)}
                </td>
                <td class="font-mono text-xs text-right">{Billing.format_cents(row.amount_cents)}</td>
                <td :if={row.code} class="font-mono text-xs">{row.code}</td>
                <td :if={!row.code} class="text-base-content/45">—</td>
                <td class="whitespace-nowrap"><.outcome_badge outcome={row.outcome} /></td>
                <td :if={row.stripe_payment_intent_id} class="font-mono text-xs">
                  {row.stripe_payment_intent_id}
                </td>
                <td :if={!row.stripe_payment_intent_id} class="text-base-content/45">—</td>
              </tr>
            </tbody>
            <tbody :if={@empty?}>
              <tr id="admin-renewals-empty">
                <td colspan="7" class="text-base-content/65">No payment attempts.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
