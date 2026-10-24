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

  defp insert_active(user, today, fields \\ []) do
    paid_through = Date.add(today, 25)
    start = Date.add(today, -5)

    account =
      insert(
        :billing_account,
        [user: user, paid_through: paid_through, billing_day: start.day] ++ card_fields() ++ fields
      )

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

  describe "promo codes" do
    setup do
      %{relayconf: insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)}
    end

    defp apply_code(view, code),
      do: view |> form("#billing-code-form", %{"promo" => %{"code" => code}}) |> render_submit()

    test "applying a code previews the discounted first charge (scenario 1)", %{conn: conn, user: user, today: today} do
      insert(:billing_account, user: user, trial_ends_on: Date.add(today, 11))
      first_charge_on = Date.add(today, 12)
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      html = apply_code(view, "relayconf")

      first_charge = squish(text(view, "#billing-first-charge"))
      assert first_charge =~ "First charge, #{mon_d(first_charge_on)} $10.00"
      assert first_charge =~ "RELAYCONF · 50% off, 3 months"
      assert first_charge =~ "then $20.00 from #{mon_d(Periods.renewal_after(first_charge_on, first_charge_on.day, 3))}"

      assert has_element?(
               view,
               "#billing-promo-terms.mt-1.flex.flex-wrap.justify-between.gap-x-2.text-base-content\\/65"
             )

      assert has_element?(view, "#billing-promo-terms span.font-mono", "then $20.00 from")
      assert has_element?(view, "#billing-promo-applied.mt-4.text-xs.text-base-content\\/55")
      assert has_element?(view, "#billing-promo-applied span.font-mono", "RELAYCONF")
      assert squish(text(view, "#billing-promo-applied")) == "Code applied: RELAYCONF. One code per account."
      assert has_element?(view, "#billing-code-form input[name='promo[code]']")
      refute has_element?(view, "#billing-code-form input[name='promo[code]'][value]:not([value=''])")
      assert html =~ "Code applied: RELAYCONF."
    end

    test "the code form is on the page with no code applied (scenario 2)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, ~s(#billing-code-form[phx-submit="apply_code"] input[placeholder="Have a code?"]))
      assert has_element?(view, "#billing-code-apply.btn.btn-sm", "Apply")
      refute has_element?(view, "#billing-promo-applied")
      refute has_element?(view, "#billing-promo-terms")
    end

    test "a disabled code is refused inline (scenario 3)", %{conn: conn, user: user} do
      insert(:promo_code, code: "OLD", disabled_at: ~U[2026-01-01 00:00:00Z])
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      apply_code(view, "OLD")

      assert has_element?(view, "#billing-code-form", "That code is no longer available.")
      assert has_element?(view, ~s(#billing-code-form input[value="OLD"]))
      assert Billing.get_account(user).promo_code_id == nil
    end

    test "an expired code is refused inline (scenario 3)", %{conn: conn, user: user, today: today} do
      insert(:promo_code, code: "PAST", expires_on: Date.add(today, -1))
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      apply_code(view, "PAST")

      assert has_element?(view, "#billing-code-form", "That code has expired.")
      assert Billing.get_account(user).promo_code_id == nil
    end

    test "a code at its cap is refused inline (scenario 3)", %{conn: conn, user: user} do
      full = insert(:promo_code, code: "FULL", max_redemptions: 1)
      insert(:billing_account, promo_code: full, promo_months_left: 3)
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      apply_code(view, "FULL")

      assert has_element?(view, "#billing-code-form", "That code is fully redeemed.")
      assert Billing.get_account(user).promo_code_id == nil
    end

    test "an unknown code is refused inline (scenario 3)", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      apply_code(view, "NOPE")

      assert has_element?(view, "#billing-code-form", "We don't recognize that code.")
      assert Billing.get_account(user).promo_code_id == nil
    end

    test "a second code is refused inline (scenario 4)", %{conn: conn, user: user, relayconf: relayconf} do
      insert(:billing_account, user: user, promo_code: relayconf, promo_months_left: 3)
      insert(:promo_code, code: "FRIENDS")
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-code-form")
      apply_code(view, "FRIENDS")

      assert has_element?(view, "#billing-code-form", "You've already used a code.")
      account = Billing.get_account(user)
      assert account.promo_code_id == relayconf.id
      assert account.promo_months_left == 3
    end

    test "every refusal has its copy (scenario 5)" do
      messages = Map.new(Billing.promo_refusals(), &{&1, RelayWeb.BillingLive.refusal_message(&1)})

      assert Enum.all?(Map.values(messages), &(is_binary(&1) and String.trim(&1) != ""))

      assert messages == %{
               unknown: "We don't recognize that code.",
               disabled: "That code is no longer available.",
               expired: "That code has expired.",
               full: "That code is fully redeemed.",
               already_redeemed: "You've already used a code."
             }
    end

    test "an active plan shows the discounted next charge (scenario 6)", %{
      conn: conn,
      user: user,
      today: today,
      relayconf: relayconf
    } do
      insert_active(user, today, promo_code_id: relayconf.id, promo_months_left: 2)
      renews_on = Date.add(today, 26)
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-next-charge.mt-4.rounded-box.bg-base-200.p-3.text-sm")
      next_charge = squish(text(view, "#billing-next-charge"))
      assert next_charge =~ "Next charge, #{mon_d(renews_on)} $10.00"
      assert next_charge =~ "RELAYCONF · 50% off, 2 months"
    end

    test "an active plan with no months left charges full price (scenario 6)", %{
      conn: conn,
      user: user,
      today: today,
      relayconf: relayconf
    } do
      insert_active(user, today, promo_code_id: relayconf.id, promo_months_left: 0)
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert squish(text(view, "#billing-next-charge")) =~ "$20.00"
      refute has_element?(view, "#billing-promo-terms")
      assert has_element?(view, "#billing-promo-applied", "RELAYCONF")
    end

    test "a 100% code needs no card yet (scenario 7)", %{conn: conn, user: user, today: today} do
      free = insert(:promo_code, code: "FREE", percent_off: 100, months: 2)
      insert(:billing_account, user: user, promo_code: free, promo_months_left: 2)
      first_charge_on = Date.add(today, 31)
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-first-charge .font-mono", "$0.00")
      no_card = squish(text(view, "#billing-no-card"))
      assert no_card =~ "No card needed until #{mon_d(Periods.renewal_after(first_charge_on, first_charge_on.day, 2))}."
      refute no_card =~ "read-only"
      assert has_element?(view, "#billing-add-card", "Add card")
    end

    test "a trial with no code still shows full price (scenario 8)", %{conn: conn, today: today} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert squish(text(view, "#billing-first-charge")) =~ "First charge, #{mon_d(Date.add(today, 31))} $20.00"
      assert has_element?(view, "#billing-first-charge .font-mono", "$20.00")
      refute has_element?(view, "#billing-promo-terms")
    end
  end
end
