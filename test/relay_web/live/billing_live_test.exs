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

  defp ordinal(day), do: RelayWeb.BillingLive.ordinal(day)

  # Scenario 8's owner: Free, boards A, B, C (owned, live), a card on B the newest activity.
  defp free_owner_of_three!(user) do
    day_ago = DateTime.add(DateTime.utc_now(:second), -86_400)
    a = insert(:board, owner: user, name: "A", updated_at: DateTime.add(day_ago, -30))
    b = insert(:board, owner: user, name: "B", updated_at: DateTime.add(day_ago, -20))
    c = insert(:board, owner: user, name: "C", updated_at: DateTime.add(day_ago, -10))
    insert(:card, stage: insert(:stage, board: b))
    %{a: a, b: b, c: c}
  end

  describe "a Free owner within the limit" do
    setup %{user: user} do
      %{board: insert(:board, owner: user, name: "Only")}
    end

    test "shows the Free badge, the board count, the Upgrade row and the code form (scenario 39)", %{
      conn: conn,
      today: today
    } do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-page")
      assert has_element?(view, "#billing-standing-badge.badge.badge-soft.badge-neutral", "Free")
      assert has_element?(view, "#billing-free-count.text-sm b", "1 of 1")
      assert squish(text(view, "#billing-free-count")) == "1 of 1 boards"

      assert has_element?(view, "#billing-upgrade.mt-4.rounded-box.bg-base-200.p-4.text-sm")
      assert has_element?(view, "#billing-upgrade .font-semibold", "Unlimited boards · $20/month")

      assert has_element?(
               view,
               "#billing-upgrade .mt-1.text-base-content\\/65",
               "Charged today, then on the #{ordinal(today.day)} of each month. Cancel anytime and you drop back to Free."
             )

      assert has_element?(view, "#billing-upgrade-button.btn.btn-primary.btn-sm.shrink-0", "Upgrade")
      assert has_element?(view, "#billing-code-form")
      refute has_element?(view, "#billing-free-over-limit-alert")
      refute has_element?(view, "#billing-free-boards")

      html = render(view)
      for gone <- ["Trial", "days left", "First charge", "No card on file"], do: refute(html =~ gone)
    end

    test "Upgrade at full price redirects to the checkout (scenario 42)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert {:error, {:redirect, %{to: url}}} = render_click(view, "upgrade")
      assert url =~ "/dev/billing-checkout"
    end

    # RE480 scenario 6
    test "the checkout return URL follows the configured host, not the request's", %{conn: conn} do
      {:ok, view, _html} = live(%{conn | host: "relayboard.fly.dev"}, ~p"/account/billing")

      assert {:error, {:redirect, %{to: url}}} = render_click(view, "upgrade")
      assert String.starts_with?(url, RelayWeb.Endpoint.url() <> "/dev/billing-checkout?")

      succeed = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("succeed")
      assert String.starts_with?(succeed, "/account/billing")
    end

    test "Upgrade with a 100% code upgrades in place, without checkout (scenario 42)", %{conn: conn, user: user} do
      insert(:promo_code, code: "FRIENDS", percent_off: 100, months: 2)
      {:ok, _account} = Billing.redeem_code(user, "FRIENDS", Date.utc_today())
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      html = view |> element("#billing-upgrade-button") |> render_click()

      assert html =~ "Upgraded. Your boards are editable."
      assert has_element?(view, "#billing-standing-badge", "Active")
      refute has_element?(view, "#billing-upgrade")
    end

    test "returning from checkout saves the card and upgrades", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account/billing?setup=local_4242_#{user.id}")

      assert has_element?(view, "#billing-card .font-mono", "Visa •••• 4242")
      assert has_element?(view, "#billing-standing-badge", "Active")
      assert render(view) =~ "Card saved and charged. Your boards are editable."
    end

    test "re-renders live when the account is paid elsewhere (scenario 44)", %{conn: conn, user: user, today: today} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")
      assert has_element?(view, "#billing-standing-badge", "Free")

      {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, today)

      assert has_element?(view, "#billing-standing-badge", "Active")
    end
  end

  describe "a Free owner over the limit (scenario 41)" do
    setup %{user: user}, do: free_owner_of_three!(user)

    test "lists the boards with the editable one first and offers to make all of them editable", %{
      conn: conn,
      today: today,
      a: a,
      b: b,
      c: c
    } do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(
               view,
               "#billing-free-over-limit-alert.alert.alert-warning[role=alert]",
               "You're on Free, so one board stays editable. The others are read-only. Nothing's been deleted."
             )

      assert squish(text(view, "#billing-free-count")) == "3 boards · 1 editable"
      assert has_element?(view, "#billing-free-count b", "3")
      assert has_element?(view, ".text-xs.font-semibold.text-base-content\\/65", "EDITABLE ON FREE")

      items =
        view
        |> element("#billing-free-boards")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      assert items == ["billing-free-board-#{b.id}", "billing-free-board-#{c.id}", "billing-free-board-#{a.id}"]

      assert has_element?(
               view,
               "#billing-free-boards.mt-1.divide-y.divide-base-300.rounded-box.border.border-base-300.text-sm"
             )

      assert has_element?(view, "#billing-free-board-#{b.id}.flex.items-center.gap-3.px-3.py-2\\.5")
      assert has_element?(view, "#billing-free-board-#{b.id} .flex-1.font-medium", "B")
      assert has_element?(view, "#billing-free-board-#{b.id} .badge.badge-success.badge-soft.badge-sm", "Editable")
      assert has_element?(view, "#billing-free-board-#{b.id} span.rounded-\\[3px\\][style*=background]")

      for read_only <- [a, c] do
        assert has_element?(view, "#billing-free-board-#{read_only.id}.text-base-content\\/65")
        assert has_element?(view, "#billing-free-board-#{read_only.id} .font-mono", "read-only")
        refute has_element?(view, "#billing-free-board-#{read_only.id} .badge")
      end

      # RE471 — read-only rows offer the switch; the editable row doesn't.
      assert has_element?(
               view,
               "#billing-free-board-#{c.id} button#billing-free-board-#{c.id}-make-editable.btn.btn-ghost.btn-xs",
               "Make editable…"
             )

      assert has_element?(view, "#billing-free-board-#{a.id}-make-editable.btn.btn-ghost.btn-xs", "Make editable…")
      refute has_element?(view, "#billing-free-board-#{b.id} button")
      refute has_element?(view, "#billing-free-board-#{b.id}-make-editable")

      assert has_element?(
               view,
               "#billing-free-boards + div#billing-free-boards-note.mt-1\\.5.text-xs.text-base-content\\/55",
               "Switch any time. We'll confirm first, because it makes the current editable board read-only. Archiving a board also frees the slot."
             )

      assert has_element?(view, "#billing-upgrade .font-semibold", "Make all 3 editable · $20/month")

      assert has_element?(
               view,
               "#billing-upgrade .mt-1",
               "Charged today. Your billing date becomes the #{ordinal(today.day)}."
             )
    end
  end

  # RE471 — switching the editable board from the Billing list, with a confirm.
  describe "switching the editable board on Free" do
    setup %{user: user}, do: free_owner_of_three!(user)

    defp board_key(board) do
      {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
      token
    end

    defp row_ids(view) do
      view
      |> element("#billing-free-boards")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("li")
      |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
    end

    test "Make editable… opens the confirm and confirming switches the pick (RE471 scenario 8)", %{
      conn: conn,
      user: user,
      a: a,
      b: b,
      c: c
    } do
      {:ok, view, _html} = live(conn, ~p"/account/billing")
      refute has_element?(view, "#make-editable-confirm")

      view |> element("#billing-free-board-#{a.id}-make-editable") |> render_click()

      assert has_element?(view, "#make-editable-confirm #make-editable-confirm-title", "Make A editable?")
      assert has_element?(view, "#make-editable-confirm", "B becomes read-only. Nothing is deleted.")

      view |> element("#make-editable-confirm-submit") |> render_click()

      refute has_element?(view, "#make-editable-confirm")
      assert has_element?(view, "#billing-free-board-#{a.id} .badge.badge-success.badge-soft.badge-sm", "Editable")
      refute has_element?(view, "#billing-free-board-#{a.id}-make-editable")
      assert has_element?(view, "#billing-free-board-#{b.id} .font-mono", "read-only")
      assert has_element?(view, "#billing-free-board-#{b.id}-make-editable", "Make editable…")
      assert row_ids(view) == ["billing-free-board-#{a.id}", "billing-free-board-#{b.id}", "billing-free-board-#{c.id}"]
      assert Billing.editable_board_id(user.id) == a.id
    end

    test "after the switch the board-key API follows the pick (RE471 scenario 9)", %{conn: conn, a: a, c: c} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")
      view |> element("#billing-free-board-#{a.id}-make-editable") |> render_click()
      view |> element("#make-editable-confirm-submit") |> render_click()

      refused =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> board_key(c))
        |> get(~p"/api/board")
        |> json_response(402)

      assert refused["error"]["code"] == "plan_paused"

      served =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> board_key(a))
        |> get(~p"/api/board")
        |> json_response(200)

      assert served["board"]["key"] == a.key
    end

    test "cancelling the confirm changes nothing (RE471 scenario 10)", %{conn: conn, user: user, b: b, c: c} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      view |> element("#billing-free-board-#{c.id}-make-editable") |> render_click()
      assert has_element?(view, "#make-editable-confirm-title", "Make C editable?")
      view |> element("#make-editable-confirm-cancel") |> render_click()

      refute has_element?(view, "#make-editable-confirm")
      assert Billing.editable_board_id(user.id) == b.id
      assert Billing.get_account(user).free_board_id == nil
      assert has_element?(view, "#billing-free-board-#{b.id} .badge", "Editable")
    end

    test "a forged confirm with another user's board is refused (RE471 scenario 10)", %{
      conn: conn,
      user: user,
      b: b
    } do
      other = insert(:board)
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      html = render_click(view, "confirm_make_editable", %{"board-id" => to_string(other.id)})

      assert html =~ "That board can&#39;t be your editable board."
      assert Billing.editable_board_id(user.id) == b.id
      assert Billing.get_account(user).free_board_id == nil
    end

    test "a forged open with another user's board opens no confirm (RE471 scenario 10)", %{conn: conn} do
      other = insert(:board)
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      html = render_click(view, "open_make_editable", %{"board-id" => to_string(other.id)})

      refute has_element?(view, "#make-editable-confirm")
      assert html =~ "That board can&#39;t be your editable board."
    end
  end

  describe "no switch outside the over-limit list (RE471 scenario 11)" do
    test "an owner within the limit gets no Make editable… and no note", %{conn: conn, user: user} do
      insert(:board, owner: user, name: "Only")
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-standing-badge", "Free")
      refute has_element?(view, "button", "Make editable…")
      refute has_element?(view, "#billing-free-boards-note")
    end

    test "an active owner gets no Make editable… and no note", %{conn: conn, user: user, today: today} do
      insert_active(user, today)
      insert(:board, owner: user, name: "One")
      insert(:board, owner: user, name: "Two")
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-standing-badge", "Active")
      refute has_element?(view, "button", "Make editable…")
      refute has_element?(view, "#billing-free-boards-note")
    end
  end

  test "ordinal/1 names the day of the month (scenario 40)" do
    expected = %{
      1 => "1st",
      2 => "2nd",
      3 => "3rd",
      4 => "4th",
      11 => "11th",
      12 => "12th",
      13 => "13th",
      21 => "21st",
      22 => "22nd",
      23 => "23rd",
      31 => "31st"
    }

    for {day, label} <- expected, do: assert(ordinal(day) == label)
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
               "Cancelling keeps unlimited boards until #{mon_d(paid_through)}, then you drop to Free (one editable board). No refunds."

      assert has_element?(
               view,
               ~s(#billing-cancel.btn.btn-ghost.btn-xs[data-confirm="Cancel your plan? You keep unlimited boards until #{mon_d(paid_through)}, then drop to Free. No refunds."]),
               "Cancel plan…"
             )

      assert has_element?(view, "#billing-next-charge", "Next charge, #{mon_d(Date.add(paid_through, 1))}")
      refute has_element?(view, "#billing-upgrade")
      refute has_element?(view, "#billing-free-count")
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

  test "a held account shows the paused alert with no Update card (scenario 45)", %{
    conn: conn,
    user: user,
    today: today
  } do
    insert(:billing_account, user: user, held_on: today, hold_reason: "test")
    {:ok, view, _html} = live(conn, ~p"/account/billing")

    assert has_element?(view, "#billing-paused-alert.alert.alert-error")

    assert text(view, "#billing-paused-alert") =~
             "Your plan is paused, so your boards are read-only. Nothing's been deleted."

    refute has_element?(view, "#billing-update-card")
    assert has_element?(view, "#billing-standing-badge.badge-error", "Paused")
    refute has_element?(view, "#billing-upgrade")
  end

  describe "a lapsed (Free) account" do
    setup %{user: user, today: today} do
      insert(:billing_account, user: user, paid_through: Date.add(today, -10), billing_day: today.day)
      :ok
    end

    test "is on Free with no paused alert", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      assert has_element?(view, "#billing-standing-badge", "Free")
      refute has_element?(view, "#billing-paused-alert")
      assert has_element?(view, "#billing-upgrade-button")
    end

    test "saving a card pays a fresh month (scenario 7)", %{conn: conn, user: user, today: today} do
      {:ok, view, _html} = live(conn, ~p"/account/billing?setup=local_4242_#{user.id}")

      {_start, period_end} = Periods.period(today, today.day)
      assert has_element?(view, "#billing-standing-badge", "Active")
      assert render(view) =~ "paid through <b>#{mon_d(period_end)}</b>"
      assert render(view) =~ "Card saved and charged. Your boards are editable."
    end
  end

  test "a comped account shows no charge and no cancel (scenario 8)", %{conn: conn, user: user} do
    insert(:billing_account, user: user, comped: true)

    {:ok, view, _html} = live(conn, ~p"/account/billing")

    assert has_element?(view, "#billing-comped", "Comped, no charge")
    refute has_element?(view, "#billing-cancel")
  end

  test "another user's setup id is refused (scenario 9)", %{conn: conn} do
    other = insert(:user)
    {:ok, before} = Billing.ensure_account(other)

    {:ok, view, _html} = live(conn, ~p"/account/billing?setup=local_4242_#{other.id}")

    assert render(view) =~ "We couldn&#39;t save that card."
    assert Billing.get_account(other) == before
  end

  describe "the off switch and the avatar menu (scenario 10)" do
    test "billing disabled: the page 404s and there is no menu item (scenario 46)", %{conn: conn} do
      Process.put(:billing_enabled, false)

      assert_error_sent 404, fn -> get(conn, ~p"/account/billing") end
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/account/billing") end

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

    test "applying a code on Free shows its terms under the Upgrade row (scenario 1)", %{
      conn: conn,
      user: user,
      today: today
    } do
      insert(:billing_account, user: user)
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      html = apply_code(view, "relayconf")

      upgrade = squish(text(view, "#billing-upgrade"))
      assert upgrade =~ "Unlimited boards · $20/month"
      assert upgrade =~ "RELAYCONF · 50% off, 3 months"
      assert upgrade =~ "then $20.00 from #{mon_d(Periods.renewal_after(today, today.day, 3))}"

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

    test "a 100% code on Free shows its terms under the Upgrade row (scenario 7)", %{
      conn: conn,
      user: user,
      today: today
    } do
      free = insert(:promo_code, code: "FREE", percent_off: 100, months: 2)
      insert(:billing_account, user: user, promo_code: free, promo_months_left: 2)
      {:ok, view, _html} = live(conn, ~p"/account/billing")

      upgrade = squish(text(view, "#billing-upgrade"))
      assert upgrade =~ "FREE · 100% off, 2 months"
      assert upgrade =~ "then $20.00 from #{mon_d(Periods.renewal_after(today, today.day, 2))}"
      assert has_element?(view, "#billing-upgrade-button", "Upgrade")
    end
  end

  # RE472: the setup-outcome copy is one public function BoardsLive's Checkout return shares.
  test "setup_flash/1 answers a declined card with its error copy" do
    assert RelayWeb.BillingLive.setup_flash({:ok, %{charged: :declined}}) == {:error, "That card was declined."}
  end
end
