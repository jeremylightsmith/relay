defmodule RelayWeb.BillingLive do
  @moduledoc """
  The board owner's Billing page, `/account/billing` (RE460, ADR 0012), reached from the avatar
  menu's **Billing** item. Renders `Relay.Billing.summary/2` by standing kind: a trial (its end,
  the first charge, the card or the no-card row), an active plan (the card, payments and the
  cancel line), a cancelled one (Resume), past due and paused (an alert with **Update card**),
  and comped.

  **Add card**, **Replace** and **Update card** all send `"add_card"`, which redirects to the
  setup Checkout (`Relay.Billing.setup_checkout_url/2`); Checkout returns here with
  `?setup=<id>`, which `handle_params/3` completes (`Relay.Billing.complete_setup/3`, checked
  against the signed-in user), flashes the outcome and patches the param away. `"cancel_plan"`
  and `"resume_plan"` call `Relay.Billing.cancel/2` / `resume/2`. The page is subscribed to the
  user's `billing:<user_id>` topic, so a webhook-settled payment re-renders it live.

  404 (`Ecto.NoResultsError`) while billing is disabled — a self-hosted install has no plan.
  """

  use RelayWeb, :live_view

  alias Relay.Billing
  alias Relay.Billing.Standing

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:title>
        <span id="billing-title">Billing</span>
      </:title>
      <div id="billing-page" class="mx-auto max-w-xl px-4 py-8">
        <h1 class="m-0 text-[27px] font-semibold tracking-tight text-base-content">Billing</h1>
        <div class="card mt-4 border border-base-300 bg-base-100 p-5">
          <div
            :if={@kind == :past_due}
            id="billing-past-due-alert"
            role="alert"
            class="alert alert-warning mb-4"
          >
            <span class="flex-1">
              Your card was declined. Update it today to keep your boards editable.
            </span>
            <.update_card_button />
          </div>
          <div
            :if={@kind == :paused}
            id="billing-paused-alert"
            role="alert"
            class="alert alert-error mb-4"
          >
            <span class="flex-1">
              Your plan is paused, so your boards are read-only. Nothing's been deleted.
            </span>
            <.update_card_button :if={@summary.standing != {:paused, :hold}} />
          </div>

          <div class="flex items-center gap-2">
            <span id="billing-standing-badge" class={["badge badge-soft", badge_class(@kind)]}>
              {badge_label(@kind)}
            </span>
            <span :if={@kind == :trial and @summary.trial_ends_on} id="billing-trial" class="text-sm">
              ends <b>{date(@summary.trial_ends_on)}</b> · {@summary.trial_days_left} days left
            </span>
            <span :if={@kind == :active} id="billing-active" class="text-sm">
              paid through <b>{date(@summary.paid_through)}</b> · renews {date(@summary.renews_on)}
            </span>
            <span :if={@kind == :cancelled} id="billing-cancelled" class="flex-1 text-sm">
              Access until {date(access_until(@summary.standing))}. Your plan won't renew.
            </span>
            <.button
              :if={@summary.resumable?}
              type="button"
              id="billing-resume"
              phx-click="resume_plan"
              class="btn btn-primary btn-sm"
            >
              Resume
            </.button>
            <span :if={@kind == :comped} id="billing-comped" class="text-sm">Comped, no charge</span>
          </div>

          <div
            :if={@kind == :trial and @summary.first_charge_on}
            id="billing-first-charge"
            class="mt-4 rounded-box bg-base-200 p-3 text-sm"
          >
            <div class="flex justify-between">
              <span>First charge, {date(@summary.first_charge_on)}</span>
              <span class="font-mono">{Billing.format_cents(@summary.amount_cents)}</span>
            </div>
          </div>

          <div
            :if={@summary.card}
            id="billing-card"
            class="mt-4 flex items-center justify-between rounded-box bg-base-200 p-3 text-sm"
          >
            <span>
              <span class="font-mono">{@summary.card.brand_label} •••• {@summary.card.last4}</span>
              <span class="text-base-content/65">exp {expiry(@summary.card)}</span>
            </span>
            <.button
              type="button"
              id="billing-replace-card"
              phx-click="add_card"
              class="btn btn-ghost btn-xs"
            >
              Replace
            </.button>
          </div>

          <div
            :if={@kind == :trial and is_nil(@summary.card)}
            id="billing-no-card"
            class="mt-4 flex items-center justify-between gap-3 border-t border-base-300 pt-4 text-sm"
          >
            <span class="text-base-content/65">
              No card on file. Without one, your boards go read-only on {date(
                @summary.first_charge_on
              )}.
            </span>
            <.button
              type="button"
              id="billing-add-card"
              phx-click="add_card"
              class="btn btn-primary btn-sm shrink-0"
            >
              Add card
            </.button>
          </div>

          <%= if @summary.payments != [] do %>
            <div class="mt-4 text-xs font-semibold text-base-content/65">PAYMENTS</div>
            <table id="billing-payments" class="table table-xs mt-1">
              <tbody>
                <tr :for={payment <- @summary.payments} id={"billing-payment-#{payment.id}"}>
                  <td class="font-mono">{date(payment.paid_on)}</td>
                  <td>{date(payment.period_start)} – {date(payment.period_end)}</td>
                  <td class="text-right font-mono">{Billing.format_cents(payment.amount_cents)}</td>
                  <td class="text-right">
                    <a
                      :if={payment.receipt_url}
                      href={payment.receipt_url}
                      target="_blank"
                      rel="noopener"
                      class="link link-hover text-xs"
                    >
                      receipt
                    </a>
                  </td>
                </tr>
              </tbody>
            </table>
          <% end %>

          <div
            :if={@kind == :active and @summary.cancellable?}
            id="billing-cancel-line"
            class="mt-4 flex flex-wrap items-center justify-end gap-2 border-t border-base-300 pt-3 text-xs text-base-content/55"
          >
            <span>Cancelling keeps access until {date(@summary.paid_through)}. No refunds.</span>
            <.button
              type="button"
              id="billing-cancel"
              phx-click="cancel_plan"
              data-confirm={"Cancel your plan? You keep access until #{date(@summary.paid_through)}. No refunds."}
              class="btn btn-ghost btn-xs text-base-content/65"
            >
              Cancel plan…
            </.button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp update_card_button(assigns) do
    ~H"""
    <.button type="button" id="billing-update-card" phx-click="add_card" class="btn btn-sm">
      Update card
    </.button>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if !Billing.enabled?(), do: raise(Ecto.NoResultsError, queryable: Schemas.BillingAccount)

    user = socket.assigns.current_scope.user
    # A user who signed up before billing has no trial yet; start it so the page shows a date.
    {:ok, _account} = Billing.ensure_trial(user, Date.utc_today())
    if connected?(socket), do: Billing.subscribe(user.id)

    {:ok, socket |> assign(:page_title, "Billing") |> assign_summary()}
  end

  # The return from Checkout. Completed once, on the connected mount (the disconnected render
  # would complete it a second time — harmless, but it would flash twice), then patched away.
  @impl true
  def handle_params(%{"setup" => setup_id}, _uri, socket) when is_binary(setup_id) do
    if connected?(socket) do
      user = socket.assigns.current_scope.user

      {:noreply,
       socket
       |> put_setup_flash(Billing.complete_setup(setup_id, user.id, Date.utc_today()))
       |> assign_summary()
       |> push_patch(to: ~p"/account/billing")}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_card", _params, socket) do
    case Billing.setup_checkout_url(socket.assigns.current_scope.user, url(~p"/account/billing")) do
      {:ok, checkout_url} -> {:noreply, redirect(socket, external: checkout_url)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "We couldn't open checkout. Try again.")}
    end
  end

  def handle_event("cancel_plan", _params, socket) do
    _result = Billing.cancel(socket.assigns.current_scope.user, Date.utc_today())
    {:noreply, assign_summary(socket)}
  end

  def handle_event("resume_plan", _params, socket) do
    _result = Billing.resume(socket.assigns.current_scope.user, Date.utc_today())
    {:noreply, assign_summary(socket)}
  end

  @impl true
  def handle_info({:billing_changed, _user_id}, socket), do: {:noreply, assign_summary(socket)}

  defp assign_summary(socket) do
    summary = Billing.summary(socket.assigns.current_scope.user, Date.utc_today())
    socket |> assign(:summary, summary) |> assign(:kind, Standing.kind(summary.standing))
  end

  defp put_setup_flash(socket, {:ok, %{charged: :paid}}),
    do: put_flash(socket, :info, "Card saved and charged. Your boards are editable.")

  defp put_setup_flash(socket, {:ok, %{charged: :none}}), do: put_flash(socket, :info, "Card saved.")
  defp put_setup_flash(socket, {:ok, %{charged: :declined}}), do: put_flash(socket, :error, "That card was declined.")

  defp put_setup_flash(socket, {:ok, %{charged: :unknown}}),
    do: put_flash(socket, :info, "Card saved. We're confirming the charge with Stripe.")

  defp put_setup_flash(socket, {:error, _reason}), do: put_flash(socket, :error, "We couldn't save that card.")

  defp badge_label(:trial), do: "Trial"
  defp badge_label(:active), do: "Active"
  defp badge_label(:past_due), do: "Past due"
  defp badge_label(:cancelled), do: "Cancelled"
  defp badge_label(:comped), do: "Comped"
  defp badge_label(:paused), do: "Paused"

  defp badge_class(:trial), do: "badge-primary"
  defp badge_class(:active), do: "badge-success"
  defp badge_class(:comped), do: "badge-success"
  defp badge_class(:paused), do: "badge-error"
  defp badge_class(_past_due_or_cancelled), do: "badge-warning"

  defp access_until({:cancelled, %Date{} = access_until}), do: access_until

  defp date(%Date{} = date), do: Calendar.strftime(date, "%b %-d")

  defp expiry(%{exp_month: month, exp_year: year}) do
    "#{month |> Integer.to_string() |> String.pad_leading(2, "0")}/#{year |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
