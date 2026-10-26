defmodule RelayWeb.BillingLive do
  @moduledoc """
  The board owner's Billing page, `/account/billing` (RE460, ADR 0012; Free since RE469), reached
  from the avatar menu's **Billing** item. Renders `Relay.Billing.summary/2` by standing kind:
  **Free** (the board count against `Relay.Billing.free_board_limit/0`; over the limit, a
  warning alert and the counted boards with the editable one marked; then the **Upgrade** row),
  an active plan (the card, payments and the cancel line), a cancelled one (Resume), past due
  (an alert with **Update card**), paused — only a superadmin hold — (an alert, no button), and
  comped.

  **Upgrade** sends `"upgrade"`: a $0 upgrade (a 100% code, `summary.upgrade_free?`) is charged
  in place (`Relay.Billing.upgrade_without_card/2`); anything else redirects to the setup
  Checkout (`Relay.Billing.setup_checkout_url/2`), and saving the card charges the upgrade.
  **Replace** and **Update card** send `"add_card"`, the same redirect. Checkout returns here
  with `?setup=<id>`, which `handle_params/3` completes (`Relay.Billing.complete_setup/3`,
  checked against the signed-in user), flashes the outcome and patches the param away.
  `"cancel_plan"` and `"resume_plan"` call `Relay.Billing.cancel/2` / `resume/2`. The page is
  subscribed to the user's `billing:<user_id>` topic, so a webhook-settled payment re-renders it
  live.

  Promo codes (RE462): the active plan's next charge shows `summary.amount_cents` (already
  discounted by `Relay.Billing.next_charge/1`), and both it and the Upgrade row show, while the
  code has months left, its terms and when the full price returns. The **Have a code?** form
  sends `"apply_code"` → `Relay.Billing.redeem_code/3`; a refusal comes back inline as the
  field's error (`refusal_message/1`, the one copy of each refusal), a success flashes and
  clears the form.

  Switching the editable board (RE471): over the limit, each read-only row has **Make editable…**
  (`"open_make_editable"`, `%{"board-id" => id}`), which opens
  `RelayWeb.FreeBoardComponents.make_editable_confirm/1` for that board (`@make_editable`, the
  chosen `free_status` board, or nil). Cancel sends `"cancel_make_editable"`; the confirm sends
  `"confirm_make_editable"` → `Relay.Billing.choose_free_board/2`, whose `{:billing_changed, _}`
  broadcast re-renders this page and flips the owner's open boards. A board id not in the list
  (forged, or archived since the page loaded) is refused with a flash, never a crash.

  404 (`Ecto.NoResultsError`) while billing is disabled — a self-hosted install has no plan.
  """

  use RelayWeb, :live_view

  alias Relay.Billing
  alias Relay.Billing.Standing
  alias RelayWeb.CoreComponents
  alias RelayWeb.FreeBoardComponents

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
          </div>
          <div
            :if={@summary.free && @summary.free.over_limit?}
            id="billing-free-over-limit-alert"
            role="alert"
            class="alert alert-warning mb-4"
          >
            <span class="flex-1">
              You're on Free, so one board stays editable. The others are read-only. Nothing's been deleted.
            </span>
          </div>

          <div class="flex items-center gap-2">
            <span id="billing-standing-badge" class={["badge badge-soft", badge_class(@kind)]}>
              {badge_label(@kind)}
            </span>
            <span :if={@summary.free} id="billing-free-count" class="text-sm">
              <%= if @summary.free.over_limit? do %>
                <b>{length(@summary.free.boards)}</b> boards · {@summary.free.limit} editable
              <% else %>
                <b>{length(@summary.free.boards)} of {@summary.free.limit}</b> boards
              <% end %>
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

          <%= if @summary.free && @summary.free.over_limit? do %>
            <div class="mt-4 text-xs font-semibold text-base-content/65">EDITABLE ON FREE</div>
            <ul
              id="billing-free-boards"
              class="mt-1 divide-y divide-base-300 rounded-box border border-base-300 text-sm"
            >
              <li
                :for={board <- @summary.free.boards}
                id={"billing-free-board-#{board.id}"}
                class={[
                  "flex items-center gap-3 px-3 py-2.5",
                  !board.editable? && "text-base-content/65"
                ]}
              >
                <span
                  class="size-[10px] shrink-0 rounded-[3px]"
                  style={"background:#{board_color(board.slug)};"}
                >
                </span>
                <span class={["flex-1", board.editable? && "font-medium"]}>{board.name}</span>
                <span :if={board.editable?} class="badge badge-success badge-soft badge-sm">
                  Editable
                </span>
                <span :if={!board.editable?} class="font-mono text-[10.5px]">read-only</span>
                <button
                  :if={!board.editable?}
                  type="button"
                  id={"billing-free-board-#{board.id}-make-editable"}
                  phx-click="open_make_editable"
                  phx-value-board-id={board.id}
                  class="btn btn-ghost btn-xs"
                >
                  Make editable…
                </button>
              </li>
            </ul>
            <div id="billing-free-boards-note" class="mt-1.5 text-xs text-base-content/55">
              Switch any time. We'll confirm first, because it makes the current editable board read-only. Archiving a board also frees the slot.
            </div>
            <FreeBoardComponents.make_editable_confirm
              :if={@make_editable}
              board_id={@make_editable.id}
              board_name={@make_editable.name}
              editable_name={editable_name(@summary.free)}
            />
          <% end %>

          <div
            :if={@summary.free}
            id="billing-upgrade"
            class="mt-4 rounded-box bg-base-200 p-4 text-sm"
          >
            <div class="flex items-start justify-between gap-4">
              <div>
                <div class="font-semibold">
                  {upgrade_title(@summary.free)} · {Billing.format_dollars(@summary.full_price_cents)}/month
                </div>
                <div class="mt-1 text-base-content/65">{upgrade_terms(@summary.free)}</div>
              </div>
              <.button
                type="button"
                id="billing-upgrade-button"
                phx-click="upgrade"
                class="btn btn-primary btn-sm shrink-0"
              >
                Upgrade
              </.button>
            </div>
            <.promo_terms summary={@summary} />
          </div>

          <div
            :if={@kind == :active}
            id="billing-next-charge"
            class="mt-4 rounded-box bg-base-200 p-3 text-sm"
          >
            <div class="flex justify-between">
              <span>Next charge, {date(@summary.renews_on)}{" "}</span>
              <span class="font-mono">{Billing.format_cents(@summary.amount_cents)}</span>
            </div>
            <.promo_terms summary={@summary} />
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
            :if={@summary.promo}
            id="billing-promo-applied"
            class="mt-4 text-xs text-base-content/55"
          >
            Code applied: <span class="font-mono">{@summary.promo.code}</span>. One code per account.
          </div>

          <.form
            for={@code_form}
            id="billing-code-form"
            phx-submit="apply_code"
            class="mt-4 flex items-start gap-2"
          >
            <div class="flex-1">
              <.input field={@code_form[:code]} placeholder="Have a code?" autocomplete="off" />
            </div>
            <.button id="billing-code-apply" class="btn btn-sm">Apply</.button>
          </.form>

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
            <span>
              Cancelling keeps unlimited boards until {date(@summary.paid_through)}, then you drop to Free (one editable board). No refunds.
            </span>
            <.button
              type="button"
              id="billing-cancel"
              phx-click="cancel_plan"
              data-confirm={"Cancel your plan? You keep unlimited boards until #{date(@summary.paid_through)}, then drop to Free. No refunds."}
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

  attr :summary, :map, required: true

  # The code's terms while it still discounts a month: "RELAYCONF · 50% off, 3 months" and when
  # the full price comes back.
  defp promo_terms(assigns) do
    ~H"""
    <div
      :if={@summary.promo && @summary.promo.months_left > 0}
      id="billing-promo-terms"
      class="mt-1 flex flex-wrap justify-between gap-x-2 text-base-content/65"
    >
      <span>
        {@summary.promo.code} · {@summary.promo.percent_off}% off, {months(@summary.promo.months_left)}
      </span>
      <span :if={@summary.promo.full_price_from} class="font-mono">
        then {Billing.format_cents(@summary.full_price_cents)} from {date(
          @summary.promo.full_price_from
        )}
      </span>
    </div>
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
    {:ok, _account} = Billing.ensure_account(user)
    if connected?(socket), do: Billing.subscribe(user.id)

    {:ok,
     socket
     |> assign(:page_title, "Billing")
     |> assign(:make_editable, nil)
     |> assign_summary()
     |> assign_code_form("")}
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
  def handle_event("add_card", _params, socket), do: {:noreply, to_checkout(socket)}

  def handle_event("upgrade", _params, socket) do
    case Billing.upgrade_without_card(socket.assigns.current_scope.user, Date.utc_today()) do
      {:ok, :paid} -> {:noreply, socket |> assign_summary() |> put_flash(:info, "Upgraded. Your boards are editable.")}
      {:error, :checkout_required} -> {:noreply, to_checkout(socket)}
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

  def handle_event("apply_code", %{"promo" => %{"code" => code}}, socket) when is_binary(code) do
    case Billing.redeem_code(socket.assigns.current_scope.user, code, Date.utc_today()) do
      {:ok, _account} ->
        applied = socket |> assign_summary() |> assign_code_form("")
        {:noreply, put_flash(applied, :info, "Code applied: #{applied.assigns.summary.promo.code}.")}

      {:error, refusal} ->
        {:noreply, assign_code_form(socket, code, refusal_message(refusal))}
    end
  end

  def handle_event("open_make_editable", %{"board-id" => board_id}, socket) do
    case free_board(socket, board_id) do
      nil -> {:noreply, refuse_make_editable(socket)}
      board -> {:noreply, assign(socket, :make_editable, board)}
    end
  end

  def handle_event("cancel_make_editable", _params, socket), do: {:noreply, assign(socket, :make_editable, nil)}

  def handle_event("confirm_make_editable", %{"board-id" => board_id}, socket) do
    with %{id: id} <- free_board(socket, board_id),
         {:ok, _account} <- Billing.choose_free_board(socket.assigns.current_scope.user, id) do
      {:noreply, socket |> assign(:make_editable, nil) |> assign_summary()}
    else
      _refused -> {:noreply, refuse_make_editable(socket)}
    end
  end

  @impl true
  def handle_info({:billing_changed, _user_id}, socket), do: {:noreply, assign_summary(socket)}

  # The setup Checkout: saving a card there pays a past-due renewal or a Free owner's upgrade.
  defp to_checkout(socket) do
    case Billing.setup_checkout_url(socket.assigns.current_scope.user, url(~p"/account/billing")) do
      {:ok, checkout_url} -> redirect(socket, external: checkout_url)
      {:error, _reason} -> put_flash(socket, :error, "We couldn't open checkout. Try again.")
    end
  end

  # RE471 — the over-limit list's board with this id, or nil (forged, or gone since the page loaded).
  defp free_board(%{assigns: %{summary: %{free: %{boards: boards}}}}, board_id),
    do: Enum.find(boards, &(to_string(&1.id) == board_id))

  defp free_board(_socket, _board_id), do: nil

  defp refuse_make_editable(socket),
    do: socket |> assign(:make_editable, nil) |> put_flash(:error, FreeBoardComponents.not_counted_message())

  defp editable_name(%{boards: boards, editable_board_id: id}), do: Enum.find_value(boards, &(&1.id == id && &1.name))

  defp assign_summary(socket) do
    summary = Billing.summary(socket.assigns.current_scope.user, Date.utc_today())
    socket |> assign(:summary, summary) |> assign(:kind, Standing.kind(summary.standing))
  end

  # A refusal comes back as the field's error with an `action`, so `<.input>` shows it inline.
  defp assign_code_form(socket, code, error \\ nil) do
    form =
      if error,
        do: to_form(%{"code" => code}, as: :promo, errors: [code: {error, []}], action: :validate),
        else: to_form(%{"code" => code}, as: :promo)

    assign(socket, :code_form, form)
  end

  @doc false
  # The copy for each of `Relay.Billing.promo_refusals/0` — defined here, the only page that shows them.
  @spec refusal_message(Billing.promo_refusal()) :: String.t()
  def refusal_message(:unknown), do: "We don't recognize that code."
  def refusal_message(:disabled), do: "That code is no longer available."
  def refusal_message(:expired), do: "That code has expired."
  def refusal_message(:full), do: "That code is fully redeemed."
  def refusal_message(:already_redeemed), do: "You've already used a code."

  # The Upgrade row's copy: within the limit, unlimited boards on the day-of-month that upgrading
  # today sets; over it, every one of the owner's boards editable again.
  defp upgrade_title(%{over_limit?: true, boards: boards}), do: "Make all #{length(boards)} editable"
  defp upgrade_title(_free), do: "Unlimited boards"

  defp upgrade_terms(%{over_limit?: true}),
    do: "Charged today. Your billing date becomes the #{ordinal(Date.utc_today().day)}."

  defp upgrade_terms(_free),
    do:
      "Charged today, then on the #{ordinal(Date.utc_today().day)} of each month. Cancel anytime and you drop back to Free."

  @doc false
  # A day of the month as people say it: 1 → "1st", 12 → "12th", 22 → "22nd".
  @spec ordinal(1..31) :: String.t()
  def ordinal(day) when day in 11..13, do: "#{day}th"

  def ordinal(day) when day in 1..31 do
    case rem(day, 10) do
      1 -> "#{day}st"
      2 -> "#{day}nd"
      3 -> "#{day}rd"
      _other -> "#{day}th"
    end
  end

  # A board's identity colour, as the `/boards` tiles draw it (`RelayWeb.BoardsLive`).
  defp board_color(slug), do: slug |> CoreComponents.identity_hue() |> CoreComponents.identity_color_for_hue()

  defp months(1), do: "1 month"
  defp months(n), do: "#{n} months"

  defp put_setup_flash(socket, {:ok, %{charged: :paid}}),
    do: put_flash(socket, :info, "Card saved and charged. Your boards are editable.")

  defp put_setup_flash(socket, {:ok, %{charged: :none}}), do: put_flash(socket, :info, "Card saved.")
  defp put_setup_flash(socket, {:ok, %{charged: :declined}}), do: put_flash(socket, :error, "That card was declined.")

  defp put_setup_flash(socket, {:ok, %{charged: :unknown}}),
    do: put_flash(socket, :info, "Card saved. We're confirming the charge with Stripe.")

  defp put_setup_flash(socket, {:error, _reason}), do: put_flash(socket, :error, "We couldn't save that card.")

  defp badge_label(:free), do: "Free"
  defp badge_label(:active), do: "Active"
  defp badge_label(:past_due), do: "Past due"
  defp badge_label(:cancelled), do: "Cancelled"
  defp badge_label(:comped), do: "Comped"
  defp badge_label(:paused), do: "Paused"

  defp badge_class(:free), do: "badge-neutral"
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
