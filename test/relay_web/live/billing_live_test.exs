defmodule RelayWeb.BillingLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Billing
  alias Relay.Billing.Payments.Local
  alias Relay.Billing.Periods

  setup :register_and_log_in_user

  setup do
    Process.put(:billing_enabled, true)
    %{today: Date.utc_today()}
  end

  defp mon_d(date), do: Calendar.strftime(date, "%b %-d")

  defp card_fields do
    card = Local.card(:visa_4242)

    [
      card_payment_method_id: card.payment_method_id,
      card_brand: card.brand,
      card_last4: card.last4,
      card_exp_month: card.exp_month,
      card_exp_year: card.exp_year,
      stripe_customer_id: "cus_local_test"
    ]
  end

  defp text(view, selector), do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp squish(string), do: string |> String.split() |> Enum.join(" ")

  defp insert_active(user, today) do
    paid_through = Date.add(today, 25)
    start = Date.add(today, -5)

    account =
      insert(:billing_account, [user: user, paid_through: paid_through, billing_day: start.day] ++ card_fields())

    payment =
      insert(:billing_payment_attempt,
        billing_account: account,
        status: :succeeded,
        period_start: start,
        period_end: paid_through,
        billing_day: start.day,
        receipt_url: "https://pay.stripe.com/receipts/test-1",
        resolved_at: DateTime.new!(start, ~T[12:00:00])
      )

    %{account: account, payment: payment, paid_through: paid_through}
  end

  describe "a trial with no card" do
    test "shows the trial, the first charge and the no-card row (scenario 1)", %{conn: conn, today: today} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-page")
      assert has_element?(view, "#billing-standing-badge.badge.badge-soft.badge-primary", "Trial")

      trial = text(view, "#billing-trial")
      assert trial =~ mon_d(Date.add(today, 30))
      assert trial =~ "30 days left"
      assert has_element?(view, "#billing-trial b", mon_d(Date.add(today, 30)))

      assert has_element?(view, "#billing-first-charge.rounded-box.bg-base-200.p-3.text-sm")
      first_charge = text(view, "#billing-first-charge")
      assert first_charge =~ "First charge, #{mon_d(Date.add(today, 31))}"
      assert has_element?(view, "#billing-first-charge .font-mono", "$20.00")

      assert has_element?(view, "#billing-no-card.border-t.border-base-300.pt-4")

      assert squish(text(view, "#billing-no-card")) =~
               "No card on file. Without one, your boards go read-only on #{mon_d(Date.add(today, 31))}."

      assert has_element?(view, "#billing-add-card.btn.btn-primary.btn-sm", "Add card")
    end

    test "Add card redirects to the checkout (scenario 2)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert {:error, {:redirect, %{to: url}}} = view |> element("#billing-add-card") |> render_click()
      assert url =~ "/dev/billing-checkout"
    end

    test "returning from checkout saves the card (scenario 3)", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account/billing?setup=local_4242_#{user.id}")

      assert has_element?(view, "#billing-card.rounded-box.bg-base-200.p-3")
      assert has_element?(view, "#billing-card .font-mono", "Visa •••• 4242")
      assert text(view, "#billing-card") =~ "exp 08/28"
      assert has_element?(view, "#billing-replace-card.btn.btn-ghost.btn-xs", "Replace")
      refute has_element?(view, "#billing-no-card")
      assert render(view) =~ "Card saved."
    end
  end

  describe "an active account" do
    setup %{user: user, today: today}, do: insert_active(user, today)

    test "shows the badge, card, payments and cancel line (scenario 4)", %{
      conn: conn,
      payment: payment,
      paid_through: paid_through
    } do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-standing-badge.badge.badge-soft.badge-success", "Active")

      assert squish(render(view)) =~
               "paid through <b>#{mon_d(paid_through)}</b> · renews #{mon_d(Date.add(paid_through, 1))}"

      assert has_element?(view, "#billing-card .font-mono", "Visa •••• 4242")
      assert has_element?(view, "#billing-card .text-base-content\\/65", "exp 08/28")
      assert has_element?(view, ".text-xs.font-semibold.text-base-content\\/65", "PAYMENTS")
      assert has_element?(view, "#billing-payments.table.table-xs")
      rows = view |> element("#billing-payments") |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("tr")
      assert Enum.count(rows) == 1
      assert has_element?(view, "#billing-payment-#{payment.id} td.text-right.font-mono", "$20.00")
      assert has_element?(view, "#billing-payment-#{payment.id} td.font-mono", mon_d(payment.period_start))

      assert has_element?(
               view,
               ~s(#billing-payment-#{payment.id} a.link.link-hover.text-xs[href="https://pay.stripe.com/receipts/test-1"][target="_blank"][rel="noopener"]),
               "receipt"
             )

      assert text(view, "#billing-payment-#{payment.id}") =~
               "#{mon_d(payment.period_start)} – #{mon_d(payment.period_end)}"

      assert has_element?(view, "#billing-cancel-line.border-t.border-base-300.pt-3.text-xs.text-base-content\\/55")

      assert squish(text(view, "#billing-cancel-line")) =~
               "Cancelling keeps access until #{mon_d(paid_through)}. No refunds."

      assert has_element?(
               view,
               ~s(#billing-cancel.btn.btn-ghost.btn-xs[data-confirm="Cancel your plan? You keep access until #{mon_d(paid_through)}. No refunds."]),
               "Cancel plan…"
             )
    end

    test "cancel then resume (scenario 5)", %{conn: conn, paid_through: paid_through} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      view |> element("#billing-cancel") |> render_click()
      assert has_element?(view, "#billing-standing-badge.badge-warning", "Cancelled")
      assert render(view) =~ "Access until #{mon_d(paid_through)}. Your plan won&#39;t renew."
      assert has_element?(view, "#billing-resume.btn.btn-primary.btn-sm", "Resume")

      view |> element("#billing-resume") |> render_click()
      assert has_element?(view, "#billing-standing-badge", "Active")
      refute has_element?(view, "#billing-resume")
    end
  end

  test "a past-due account shows the declined alert (scenario 6)", %{conn: conn, user: user, today: today} do
    insert(:billing_account, [user: user, paid_through: Date.add(today, -1), billing_day: today.day] ++ card_fields())

    {:ok, view, _html} = live(conn, ~p"/account/billing")

    assert has_element?(view, "#billing-past-due-alert.alert.alert-warning", "Your card was declined.")
    assert text(view, "#billing-past-due-alert") =~ "Update it today to keep your boards editable."
    assert has_element?(view, "#billing-update-card.btn.btn-sm", "Update card")
  end

  describe "a paused account" do
    setup %{user: user, today: today} do
      insert(:billing_account, user: user, paid_through: Date.add(today, -10), billing_day: today.day)
      :ok
    end

    test "shows the paused alert (scenario 7)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-paused-alert.alert.alert-error")

      assert text(view, "#billing-paused-alert") =~
               "Your plan is paused, so your boards are read-only. Nothing's been deleted."

      assert has_element?(view, "#billing-update-card.btn.btn-sm", "Update card")
    end

    test "saving a card pays a fresh month (scenario 7)", %{conn: conn, user: user, today: today} do
      {:ok, view, _html} = live(conn, ~p"/account/billing?setup=local_4242_#{user.id}")

      {_start, period_end} = Periods.period(today, today.day)
      assert has_element?(view, "#billing-standing-badge", "Active")
      assert render(view) =~ "paid through <b>#{mon_d(period_end)}</b>"
      assert render(view) =~ "Card saved and charged. Your boards are editable."
    end

    test "re-renders live when the webhook pays (scenario 11)", %{conn: conn, user: user, today: today} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")
      assert has_element?(view, "#billing-paused-alert")

      {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, today)

      assert has_element?(view, "#billing-standing-badge", "Active")
      refute has_element?(view, "#billing-paused-alert")
    end
  end

  test "a comped account shows no charge and no cancel (scenario 8)", %{conn: conn, user: user} do
    insert(:billing_account, user: user, comped: true)

    {:ok, view, _html} = live(conn, ~p"/account/billing")

    assert has_element?(view, "#billing-comped", "Comped, no charge")
    refute has_element?(view, "#billing-cancel")
  end

  test "another user's setup id is refused (scenario 9)", %{conn: conn, today: today} do
    other = insert(:user)
    {:ok, before} = Billing.ensure_trial(other, today)

    {:ok, view, _html} = live(conn, ~p"/account/billing?setup=local_4242_#{other.id}")

    assert render(view) =~ "We couldn&#39;t save that card."
    assert Billing.get_account(other) == before
  end

  describe "the off switch and the avatar menu (scenario 10)" do
    test "billing disabled: the page 404s and there is no menu item", %{conn: conn} do
      Process.put(:billing_enabled, false)

      assert_error_sent 404, fn -> get(conn, ~p"/account/billing") end

      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#billing-link")
    end

    test "billing enabled: the menu links to the Billing page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, ~s(#account-menu li #billing-link[href="/account/billing"]), "Billing")
    end
  end
end
