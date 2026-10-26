defmodule HamacaWeb.Admin.UsersLiveTest do
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Hamaca.Billing
  alias Hamaca.Billing.Payments.Local
  alias Hamaca.Boards
  alias Hamaca.Repo
  alias HamacaWeb.Admin.UsersLive
  alias Schemas.BillingAccount
  alias Schemas.BillingAdminEntry
  alias Schemas.BillingPaymentAttempt
  alias Schemas.Scope

  setup %{conn: conn} do
    admin = insert(:user, email: hd(Scope.superadmin_emails()))
    today = Date.utc_today()

    free = insert(:user, name: "Sam Ortiz")
    free_board = insert(:board, owner: free)
    insert(:billing_account, user: free)

    card = Local.card(:visa_4242)
    promo = insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)
    active = insert(:user, name: "Ada Byron")
    insert(:board, owner: active)

    insert(:billing_account,
      user: active,
      paid_through: Date.add(today, 20),
      promo_code_id: promo.id,
      promo_months_left: 2,
      card_payment_method_id: card.payment_method_id,
      card_brand: card.brand,
      card_last4: card.last4
    )

    paused = insert(:user, name: "Lee Park")
    insert(:board, owner: paused)
    insert(:billing_account, user: paused, paid_through: Date.add(today, 10), held_on: today, hold_reason: "fraud check")

    comped = insert(:user, name: "Jeremy L.")
    insert(:board, owner: comped)
    insert(:billing_account, user: comped, comped: true)

    member = insert(:user, name: "Kai")
    insert(:membership, board: free_board, user: member)

    %{
      conn: log_in_user(conn, admin),
      free: free,
      active: active,
      paused: paused,
      comped: comped,
      member: member
    }
  end

  defp cell(view, user, suffix), do: view |> element("#admin-user-#{user.id}-#{suffix}") |> render()

  # The text a browser shows: whitespace runs collapse to one space.
  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  test "the RELAYCONF row shows its discounted rate, the code's progress and an active badge", %{
    conn: conn,
    active: active
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert text(cell(view, active, "rate")) == "$10"
    assert text(cell(view, active, "code")) == "RELAYCONF 1/3"
    assert has_element?(view, "#admin-user-#{active.id}-plan .badge.badge-soft.badge-success", "active")
  end

  test "the comped row reads $0 with a neutral comped badge", %{conn: conn, comped: comped} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert text(cell(view, comped, "rate")) == "$0"
    assert has_element?(view, "#admin-user-#{comped.id}-plan .badge.badge-soft.badge-neutral", "comped")
  end

  test "the held row carries a warning paused badge", %{conn: conn, paused: paused} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert has_element?(view, "#admin-user-#{paused.id}-plan .badge.badge-soft.badge-warning", "paused")
  end

  test "the never-paid row carries a free badge and no paid through", %{conn: conn, free: free} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert has_element?(view, "#admin-user-#{free.id}-plan .badge.badge-soft.badge-primary", "free")
    refute render(view) =~ ~r/>\s*trial\s*</
    assert text(cell(view, free, "paid-through")) == "—"
  end

  test "the member-only row carries a ghost badge and dashes for every billing cell", %{
    conn: conn,
    member: member
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert has_element?(view, "#admin-user-#{member.id}-plan .badge.badge-ghost", "member only")

    for suffix <- ["rate", "code", "members", "paid-through"] do
      assert text(cell(view, member, suffix)) == "—"
      assert has_element?(view, "#admin-user-#{member.id}-#{suffix}.text-base-content\\/45")
    end
  end

  test "renders full width, not inside the layout's narrow max-w-2xl column", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")
    refute has_element?(view, "main div.max-w-2xl")
  end

  test "the summary counts users, paying, the monthly total and Free owners", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    assert view |> element("#admin-users-summary") |> render() |> text() ==
             "6 users · 1 paying · $10/mo · 1 on Free"

    assert has_element?(view, "#admin-users-summary span.text-success", "$10/mo")
  end

  test "the header lists the billing columns without Provider, under the Users tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    headers =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#admin-users-table thead th")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert headers == ["Name", "Email", "Boards", "Members", "Plan", "Paid through", "Rate", "Code", "Created"]
    assert has_element?(view, "#admin-tab-users.tab-active")
  end

  describe "the row side panel" do
    # An owner with a real board (stages and all) open in their own LiveView.
    defp owner_with_open_board(account_attrs) do
      owner = insert(:user)
      {:ok, board} = Boards.create_board(owner, %{name: "Owned", key: "OW"})
      insert(:billing_account, Map.merge(%{user: owner}, account_attrs))
      {:ok, board_view, _html} = live(log_in_user(build_conn(), owner), ~p"/board/#{board.slug}")
      {owner, board_view}
    end

    defp card_fields(card) do
      card = Local.card(card)
      %{card_payment_method_id: card.payment_method_id, card_brand: card.brand, card_last4: card.last4}
    end

    defp open_panel(conn, user) do
      {:ok, view, _html} = live(conn, ~p"/admin/users?user=#{user.id}")
      view
    end

    defp entry_count(user) do
      Repo.aggregate(
        from(e in BillingAdminEntry,
          join: a in BillingAccount,
          on: a.id == e.billing_account_id,
          where: a.user_id == ^user.id
        ),
        :count
      )
    end

    defp attempt_count(user) do
      Repo.aggregate(
        from(p in BillingPaymentAttempt,
          join: a in BillingAccount,
          on: a.id == p.billing_account_id,
          where: a.user_id == ^user.id
        ),
        :count
      )
    end

    # Scenario 20
    test "clicking a row opens the panel; close removes it", %{conn: conn, paused: paused} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      refute has_element?(view, "#admin-user-panel")

      view |> element("#admin-user-#{paused.id}") |> render_click()

      assert_patch(view, "/admin/users?user=#{paused.id}")
      assert has_element?(view, "#admin-user-panel", paused.email)
      assert has_element?(view, "#admin-user-panel-plan .badge-warning", "paused")
      assert has_element?(view, "#admin-user-panel-facts", "Paid through")
      assert has_element?(view, "#admin-user-attempts-empty")
      assert has_element?(view, "#admin-user-entries-empty")
      assert has_element?(view, "#admin-user-comp")
      refute has_element?(view, "#admin-user-hold")
      assert has_element?(view, "#admin-user-lift-hold")
      assert has_element?(view, "#admin-user-extend")
      refute has_element?(view, "#admin-user-retry")
      # Hold / Extend only reveal their form; the form's submit is the one confirmation.
      refute has_element?(view, "#admin-user-hold[data-confirm]")
      refute has_element?(view, "#admin-user-extend[data-confirm]")

      view |> element("#admin-user-panel-close") |> render_click()

      assert_patch(view, "/admin/users")
      refute has_element?(view, "#admin-user-panel")
    end

    test "an unparsable or unknown user param opens no panel", %{conn: conn} do
      for param <- ["nope", "-1", "999999999"] do
        {:ok, view, _html} = live(conn, "/admin/users?user=#{param}")
        refute has_element?(view, "#admin-user-panel")
      end
    end

    # Scenario 21 (acceptance 2)
    test "comping a Free owner makes their row comped", %{conn: conn, free: free} do
      view = open_panel(conn, free)
      assert has_element?(view, "#admin-user-panel-plan", "free")

      view |> element("#admin-user-comp") |> render_click()

      assert has_element?(view, "#admin-user-#{free.id}-plan", "comped")
      assert has_element?(view, "#admin-user-uncomp")
      assert has_element?(view, "#admin-user-entries [id^=admin-entry-]")
    end

    test "lifting a hold un-pauses the owner's open board live", %{conn: conn} do
      Process.put(:billing_enabled, true)
      today = Date.utc_today()
      {owner, board_view} = owner_with_open_board(%{held_on: today, hold_reason: "fraud check"})
      assert has_element?(board_view, "#read-only-banner")

      view = open_panel(conn, owner)
      view |> element("#admin-user-lift-hold") |> render_click()

      refute has_element?(view, "#admin-user-#{owner.id}-plan", "paused")
      refute has_element?(board_view, "#read-only-banner")
    end

    test "the panel shows no Trial ends fact", %{conn: conn, free: free} do
      view = open_panel(conn, free)
      refute has_element?(view, "#admin-user-panel-facts", "Trial ends")
      refute render(view) =~ "Trial ends"
    end

    # Scenario 22 (acceptance 3)
    test "holding an active owner pauses their open board live", %{conn: conn} do
      Process.put(:billing_enabled, true)
      today = Date.utc_today()
      {owner, board_view} = owner_with_open_board(%{paid_through: Date.add(today, 10), billing_day: today.day})
      refute has_element?(board_view, "#read-only-banner")

      view = open_panel(conn, owner)
      view |> element("#admin-user-hold") |> render_click()
      view |> form("#admin-hold-form", hold: %{reason: "chargeback"}) |> render_submit()

      assert has_element?(view, "#admin-user-#{owner.id}-plan", "paused")
      assert has_element?(view, "#admin-user-lift-hold")
      refute has_element?(view, "#admin-hold-form")
      assert has_element?(board_view, "#read-only-banner")
    end

    # Scenario 23 (acceptance 4)
    test "extending moves paid through on, charges nothing and records one entry", %{conn: conn} do
      today = Date.utc_today()
      owner = insert(:user)
      insert(:board, owner: owner)
      insert(:billing_account, user: owner, paid_through: Date.add(today, 10), billing_day: today.day)

      view = open_panel(conn, owner)
      view |> element("#admin-user-extend") |> render_click()
      view |> form("#admin-extend-form", extend: %{days: "7", reason: "goodwill"}) |> render_submit()

      assert view |> element("#admin-user-#{owner.id}-paid-through") |> render() |> text() ==
               Date.to_iso8601(Date.add(today, 17))

      assert attempt_count(owner) == 0

      assert view
             |> element("#admin-user-entries")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("[id^=admin-entry-]")
             |> Enum.count() == 1
    end

    test "the extend form defaults to 7 days and cancel closes it", %{conn: conn, active: active} do
      view = open_panel(conn, active)
      view |> element("#admin-user-extend") |> render_click()

      assert has_element?(view, ~s(#admin-extend-form input[name="extend[days]"][value="7"]))

      view |> element("#admin-extend-form [phx-click=cancel_form]") |> render_click()
      refute has_element?(view, "#admin-extend-form")
    end

    # Scenario 24
    test "a blank hold reason flashes the refusal and writes nothing", %{conn: conn, active: active} do
      view = open_panel(conn, active)
      view |> element("#admin-user-hold") |> render_click()
      html = view |> form("#admin-hold-form", hold: %{reason: "  "}) |> render_submit()

      assert html =~
               :reason_required
               |> UsersLive.refusal_message()
               |> Phoenix.HTML.html_escape()
               |> Phoenix.HTML.safe_to_string()

      assert entry_count(active) == 0
      assert Billing.get_account(active).held_on == nil
    end

    # Scenario 25
    test "retrying a past-due owner's charge adds a paid attempt and makes the row active", %{conn: conn} do
      today = Date.utc_today()
      owner = insert(:user)
      insert(:board, owner: owner)

      insert(
        :billing_account,
        Map.merge(%{user: owner, paid_through: Date.add(today, -1), billing_day: today.day}, card_fields(:visa_4242))
      )

      view = open_panel(conn, owner)
      assert has_element?(view, "#admin-user-#{owner.id}-plan", "past due")

      view |> element("#admin-user-retry") |> render_click()

      assert has_element?(view, "#admin-user-attempts [id^=admin-attempt-] .badge", "paid")
      assert has_element?(view, "#admin-user-#{owner.id}-plan", "active")
    end

    # Scenario 26
    test "Open in Stripe links the customer in a new tab", %{conn: conn} do
      owner = insert(:user)
      insert(:billing_account, user: owner, stripe_customer_id: "cus_9")

      view = open_panel(conn, owner)

      assert has_element?(view, ~s(#admin-user-stripe[href$="/customers/cus_9"][target="_blank"][rel="noopener"]))
    end

    test "no Stripe customer, no Open in Stripe", %{conn: conn, paused: paused} do
      view = open_panel(conn, paused)
      refute has_element?(view, "#admin-user-stripe")
    end
  end

  # Scenario 27
  test "every admin refusal has a message" do
    for refusal <- Billing.admin_refusals() do
      assert is_binary(UsersLive.refusal_message(refusal))
      assert String.trim(UsersLive.refusal_message(refusal)) != ""
    end
  end

  test "outcome_badge/1 styles and labels every attempt outcome" do
    expected = %{
      paid: {"badge badge-sm badge-soft badge-success", "paid"},
      declined: {"badge badge-sm badge-soft badge-error", "declined"},
      unknown: {"badge badge-sm badge-soft badge-warning", "unknown"},
      not_charged: {"badge badge-sm badge-ghost", "not charged"}
    }

    for outcome <- Billing.attempt_outcomes() do
      [badge] =
        (&HamacaWeb.AdminComponents.outcome_badge/1)
        |> render_component(outcome: outcome)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("span")
        |> Enum.to_list()

      assert {badge |> LazyHTML.attribute("class") |> hd(), LazyHTML.text(badge)} == expected[outcome]
    end
  end
end
