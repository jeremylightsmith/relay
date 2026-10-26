defmodule HamacaWeb.Admin.RenewalsLiveTest do
  # RE463 — the superadmin's Renewals tab: every payment attempt across accounts, newest first,
  # filterable by outcome. Read-only: the billing clock is automatic.
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Billing
  alias Hamaca.Billing.Payments.Local
  alias Hamaca.Repo
  alias Schemas.BillingPaymentAttempt
  alias Schemas.Scope

  @path "/admin/users/renewals"

  setup %{conn: conn} do
    admin = insert(:user, email: hd(Scope.superadmin_emails()))
    %{conn: log_in_user(conn, admin)}
  end

  defp cell(view, row, n), do: view |> element("#{row} td:nth-child(#{n})") |> render()

  defp card_fields(card) do
    card = Local.card(card)

    %{
      card_payment_method_id: card.payment_method_id,
      card_brand: card.brand,
      card_last4: card.last4,
      card_exp_month: card.exp_month,
      card_exp_year: card.exp_year,
      stripe_customer_id: "cus_test"
    }
  end

  # An owner past due today on `card`, so the clock charges them.
  defp past_due_owner(card) do
    today = Date.utc_today()
    owner = insert(:user)
    insert(:board, owner: owner)

    account =
      insert(
        :billing_account,
        Map.merge(
          %{user: owner, trial_ends_on: Date.add(today, -60), paid_through: Date.add(today, -1), billing_day: today.day},
          card_fields(card)
        )
      )

    {owner, account}
  end

  defp attempt_of(account), do: Repo.get_by!(BillingPaymentAttempt, billing_account_id: account.id)

  # Scenario 4 (acceptance 5)
  test "lists the clock's attempts and filters to the declined one", %{conn: conn} do
    Process.put(:billing_enabled, true)
    {_paid_owner, paid_account} = past_due_owner(:visa_4242)
    {declined_owner, declined_account} = past_due_owner(:visa_0341)
    Billing.run_clock(Date.utc_today())

    paid = attempt_of(paid_account)
    declined = attempt_of(declined_account)

    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#renewal-#{paid.id}")
    assert has_element?(view, "#renewal-#{declined.id}")

    view |> element("#renewals-filter-declined") |> render_click()

    assert_patch(view, "/admin/users/renewals?outcome=declined")
    refute has_element?(view, "#renewal-#{paid.id}")
    row = "#renewal-#{declined.id}"
    assert has_element?(view, row)
    assert cell(view, row, 1) =~ Date.to_iso8601(Date.utc_today())
    assert cell(view, row, 2) =~ declined_owner.email
    assert cell(view, row, 4) =~ "$20.00"
    assert has_element?(view, "#{row} .badge", "declined")
    assert has_element?(view, "#renewals-filter-declined.tab-active")
    refute has_element?(view, "#renewals-filter-all.tab-active")
  end

  # Scenario 5
  test "a row shows its PaymentIntent id and its period as ISO dates", %{conn: conn} do
    attempt =
      insert(:billing_payment_attempt,
        status: :succeeded,
        stripe_payment_intent_id: "pi_123",
        period_start: ~D[2026-06-01],
        period_end: ~D[2026-06-30]
      )

    {:ok, view, _html} = live(conn, @path)

    row = "#renewal-#{attempt.id}"
    assert has_element?(view, row, "pi_123")
    assert cell(view, row, 3) =~ "2026-06-01 – 2026-06-30"
  end

  # Scenario 6
  test "an unknown outcome param lists every attempt under All", %{conn: conn} do
    paid = insert(:billing_payment_attempt, status: :succeeded)
    declined = insert(:billing_payment_attempt, status: :failed)

    {:ok, view, _html} = live(conn, @path <> "?outcome=bogus")

    assert has_element?(view, "#renewal-#{paid.id}")
    assert has_element?(view, "#renewal-#{declined.id}")
    assert has_element?(view, "#renewals-filter-all.tab-active")
    refute has_element?(view, "#renewals-filter-paid.tab-active")
  end

  # Scenario 7
  test "renders full width, not inside the layout's narrow max-w-2xl column", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users/renewals")
    refute has_element?(view, "main div.max-w-2xl")
  end

  test "no attempts shows the empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#admin-renewals-empty")
  end

  # Scenario 8
  test "Renewals is the active tab here and an inactive link on /admin/users", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#admin-tab-renewals.tab-active", "Renewals")

    {:ok, users, _html} = live(conn, ~p"/admin/users")
    assert has_element?(users, ~s(#admin-tab-renewals[href="/admin/users/renewals"]))
    refute has_element?(users, "#admin-tab-renewals.tab-active")
  end

  # Scenario 9
  test "offers no way to run billing", %{conn: conn} do
    insert(:billing_payment_attempt, status: :failed)
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#admin-renewals-page")
    refute has_element?(view, "#admin-renewals-page button")
    refute render(view) =~ "Run billing"
  end

  test "the filter tabs come from every attempt outcome", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, ~s(#renewals-filter[role="tablist"]))

    for outcome <- Billing.attempt_outcomes() do
      assert has_element?(view, ~s(#renewals-filter-#{outcome}[href="/admin/users/renewals?outcome=#{outcome}"]))
    end
  end
end
