defmodule RelayWeb.Admin.PromoCodesLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Billing
  alias Schemas.Scope

  @path "/admin/users/promo-codes"

  @relayconf %{
    "code" => "RELAYCONF",
    "percent_off" => "50",
    "months" => "3",
    "max_redemptions" => "200",
    "expires_on" => "2026-12-31"
  }

  setup %{conn: conn} do
    admin = insert(:user, email: hd(Scope.superadmin_emails()))
    %{conn: log_in_user(conn, admin)}
  end

  defp cell(view, row, n), do: view |> element("#{row} td:nth-child(#{n})") |> render()

  defp open_form(view), do: view |> element("#promo-new-code") |> render_click()

  defp submit(view, attrs), do: view |> form("#promo-code-form", promo_code: attrs) |> render_submit()

  defp codes_named(code), do: Enum.filter(Billing.list_promo_codes(), &(&1.promo_code.code == code))

  test "creating a code lists it, flashes and hides the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    refute has_element?(view, "#promo-code-form")
    open_form(view)
    assert has_element?(view, "#promo-code-form")

    submit(view, @relayconf)

    assert [%{promo_code: %{id: id}}] = codes_named("RELAYCONF")
    row = "#promo-code-#{id}"
    assert cell(view, row, 1) =~ ~r/<td class="font-mono">\s*RELAYCONF\s*</
    assert cell(view, row, 2) =~ ~r/>\s*50%\s*</
    assert cell(view, row, 3) =~ ~r/>\s*3\s*</
    assert cell(view, row, 4) =~ ~r/class="tabular-nums">\s*0 \/ 200\s*</
    assert cell(view, row, 5) =~ ~r/class="font-mono text-xs">\s*2026-12-31\s*</
    assert has_element?(view, "#{row} td.text-right #promo-code-#{id}-disable.btn.btn-ghost.btn-xs", "Disable")
    assert has_element?(view, "#flash-info", "Created RELAYCONF.")
    refute has_element?(view, "#promo-code-form")
  end

  test "Cancel hides the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    open_form(view)
    view |> element("#promo-code-cancel") |> render_click()

    refute has_element?(view, "#promo-code-form")
  end

  test "an uncapped, unexpiring code shows its holders over a dash and never", %{conn: conn} do
    friends = insert(:promo_code, code: "FRIENDS", percent_off: 100, months: 12)
    for _ <- 1..3, do: insert(:billing_account, promo_code_id: friends.id, promo_months_left: 12)

    {:ok, view, _html} = live(conn, @path)

    row = "#promo-code-#{friends.id}"
    assert cell(view, row, 2) =~ ~r/>\s*100%\s*</
    assert cell(view, row, 3) =~ ~r/>\s*12\s*</
    assert cell(view, row, 4) =~ ~r/>\s*3 \/ —\s*</
    assert cell(view, row, 5) =~ ~r/class="text-base-content\/45">\s*never\s*</
  end

  test "a duplicate code (any case) re-renders the form with already exists", %{conn: conn} do
    insert(:promo_code, code: "RELAYCONF")
    {:ok, view, _html} = live(conn, @path)

    open_form(view)
    html = submit(view, %{@relayconf | "code" => "relayconf"})

    assert html =~ "already exists"
    assert has_element?(view, "#promo-code-form")
    assert [_one] = codes_named("RELAYCONF")
  end

  test "a 0 percent off shows an error on Percent off and creates nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    open_form(view)
    submit(view, %{@relayconf | "percent_off" => "0"})

    assert has_element?(view, "#promo-code-form")

    assert view |> element("#promo-code-form .fieldset", "Percent off") |> render() =~
             "must be greater than or equal to 1"

    assert Billing.list_promo_codes() == []
  end

  test "validate shows changeset errors as you type", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    open_form(view)
    html = view |> form("#promo-code-form", promo_code: %{"percent_off" => "101"}) |> render_change()

    assert html =~ "must be less than or equal to 100"
  end

  test "disabling a code badges it and leaves existing holders their months", %{conn: conn} do
    code = insert(:promo_code, code: "RELAYCONF")
    account = insert(:billing_account, promo_code_id: code.id, promo_months_left: 2)

    {:ok, view, _html} = live(conn, @path)

    button = "#promo-code-#{code.id}-disable"

    assert view |> element(button) |> render() =~
             ~s(data-confirm="Disable RELAYCONF? Accounts that already redeemed it keep their remaining months.")

    view |> element(button) |> render_click()

    assert has_element?(view, "#promo-code-#{code.id} .badge.badge-ghost.badge-sm", "disabled")
    refute has_element?(view, button)
    assert has_element?(view, "#flash-info", "Disabled RELAYCONF.")
    assert Relay.Repo.reload!(account).promo_months_left == 2
  end

  test "no codes shows the empty row", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#admin-promo-codes-empty", "No codes yet.")
  end

  test "the Promo codes tab is active and the Users tab navigates to /admin/users", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#admin-tab-promo-codes.tab.tab-active")
    assert has_element?(view, ~s(#admin-tab-users[href="/admin/users"]))
    refute has_element?(view, "#admin-tab-users.tab-active")

    assert {:ok, _users, _html} =
             view |> element("#admin-tab-users") |> render_click() |> follow_redirect(conn, "/admin/users")
  end

  test "user_tabs renders one active tab inside the daisyUI tablist" do
    html = render_component(&RelayWeb.AdminComponents.user_tabs/1, active: :promo_codes)
    doc = LazyHTML.from_fragment(html)

    assert doc |> LazyHTML.query(~s(div[role="tablist"].tabs.tabs-box.tabs-sm#admin-user-tabs)) |> Enum.count() == 1
    assert doc |> LazyHTML.query(".tab-active") |> Enum.count() == 1

    assert doc
           |> LazyHTML.query(~s(div[role="tablist"] a[role="tab"].tab.tab-active#admin-tab-promo-codes))
           |> LazyHTML.text() =~
             "Promo codes"

    assert doc |> LazyHTML.query(~s(a[role="tab"].tab#admin-tab-users)) |> LazyHTML.text() =~ "Users"

    assert doc |> LazyHTML.query(~s(a[role="tab"])) |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
             ["Users", "Usage", "Promo codes", "Renewals"]

    assert doc |> LazyHTML.query(~s(a[role="tab"].tab#admin-tab-usage)) |> LazyHTML.attribute("href") ==
             ["/admin/users/usage"]
  end
end
