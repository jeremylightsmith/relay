defmodule RelayWeb.Admin.UsageLiveTest do
  @moduledoc """
  RE475 — the superadmin Usage tab at `/admin/users/usage`: the tiles, the range-driven
  people/agents chart, the searchable users-by-last-seen table and the `?user=` panel, read from
  `Relay.Usage`. Visits are inserted relative to `DateTime.utc_now()` so the page's `now` sees them.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Repo
  alias RelayWeb.Admin.UsageLive
  alias Schemas.Scope
  alias Schemas.UsageVisit
  alias Schemas.User

  setup %{conn: conn} do
    admin = insert(:user, email: hd(Scope.superadmin_emails()), name: "Root Admin")
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  # One visit ending `ago` seconds before now and lasting `seconds`.
  defp visit(user, attrs \\ []) do
    last_at = DateTime.add(now(), -Keyword.get(attrs, :ago, 60))
    seconds = Keyword.get(attrs, :seconds, 60)

    Repo.insert!(%UsageVisit{
      user_id: user.id,
      started_at: DateTime.add(last_at, -seconds),
      last_at: last_at,
      seconds: seconds,
      board_id: Keyword.get(attrs, :board_id),
      card_refs: Keyword.get(attrs, :card_refs, [])
    })
  end

  defp text(view, selector) do
    view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp attrs(view, selector, name) do
    view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp today_bar, do: "#usage-chart-bar-#{Date.to_iso8601(Date.utc_today())}"

  defp position(html, needle), do: html |> :binary.match(needle) |> elem(0)

  test "renders the tiles, the chart and the users table under the active Usage tab (scenario 1)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users/usage")

    for id <- ~w(usage-tile-active-today usage-tile-this-week usage-tile-agent-runs usage-tile-median-visit
                 usage-chart usage-users-table) do
      assert has_element?(view, "##{id}")
    end

    assert has_element?(view, "#admin-tab-usage.tab-active")
    assert page_title(view) =~ "Admin · Usage"
  end

  test "a user's row shows when, where and how much they were last seen (scenario 3)", %{conn: conn} do
    a = insert(:user, name: "Ada")
    board = insert(:board, name: "Pipeline", owner: a)
    visit(a, ago: 300, board_id: board.id, card_refs: ["PI12"])

    {:ok, view, _html} = live(conn, ~p"/admin/users/usage")

    assert text(view, "#usage-user-#{a.id}-last-seen") =~ "5m ago"
    assert text(view, "#usage-user-#{a.id}-last-seen") =~ "Pipeline · PI12"
    assert text(view, "#usage-user-#{a.id}-visits") == "1"
    assert view |> attrs("#usage-user-#{a.id}-strip span[data-state]", "data-state") |> List.last() == "human"
  end

  test "the superadmin is listed with a not-counted badge but left out of the tiles and chart (scenario 4)", %{
    conn: conn,
    admin: admin
  } do
    visit(admin, ago: 60)

    {:ok, view, _html} = live(conn, ~p"/admin/users/usage")

    assert text(view, "#usage-user-#{admin.id}-not-counted.badge.badge-xs.badge-ghost") == "you · not counted"
    assert text(view, "#usage-user-#{admin.id}-visits") == "1"
    assert text(view, "#usage-tile-active-today div.text-3xl") == "0"
    assert attrs(view, today_bar(), "data-people") == ["0"]
  end

  test "dev and seed accounts are left out of the table (scenario 5)", %{conn: conn} do
    synthetic =
      for provider <- User.synthetic_providers() do
        user = insert(:user, provider: provider)
        visit(user)
        user
      end

    {:ok, view, _html} = live(conn, ~p"/admin/users/usage")

    for user <- synthetic, do: refute(has_element?(view, "#usage-user-#{user.id}"))
  end

  test "a run on a user's board shows in their runs, strip and today's agents bar (scenario 6)", %{conn: conn} do
    b = insert(:user, name: "Bea")
    board = insert(:board, owner: b)
    card = insert(:card, stage: insert(:stage, board: board))
    insert(:run, card: card, status: :done, started_at: now())

    {:ok, view, _html} = live(conn, ~p"/admin/users/usage")

    assert text(view, "#usage-user-#{b.id}-runs span.text-secondary") == "1"
    assert view |> attrs("#usage-user-#{b.id}-strip span[data-state]", "data-state") |> List.last() == "agent"
    assert attrs(view, today_bar(), "data-agents") == ["1"]
  end

  test "the range select patches the URL and redraws the chart with that many days (scenario 7)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users/usage")

    view |> form("#usage-range-form", %{range: "7"}) |> render_change()
    assert_patch(view, ~p"/admin/users/usage?range=7")
    assert view |> attrs(~s(#usage-chart [id^="usage-chart-bar-"]), "id") |> length() == 7

    view |> form("#usage-range-form", %{range: "90"}) |> render_change()
    assert_patch(view, ~p"/admin/users/usage?range=90")
    assert view |> attrs(~s(#usage-chart [id^="usage-chart-bar-"]), "id") |> length() == 90

    {:ok, view, _html} = live(conn, ~p"/admin/users/usage?range=banana")
    assert view |> attrs(~s(#usage-chart [id^="usage-chart-bar-"]), "id") |> length() == 30
  end

  test "search filters rows by name or email, case-insensitively (scenario 8)", %{conn: conn} do
    ada = insert(:user, name: "Ada Byron", email: "ada@pipeline.dev")
    nate = insert(:user, name: "Nathan Stell", email: "nate@stell.io")

    {:ok, view, _html} = live(conn, ~p"/admin/users/usage")

    view |> form("#usage-search", %{q: "PIPE"}) |> render_change()
    assert has_element?(view, "#usage-user-#{ada.id}")
    refute has_element?(view, "#usage-user-#{nate.id}")

    view |> form("#usage-search", %{q: ""}) |> render_change()
    assert has_element?(view, "#usage-user-#{ada.id}")
    assert has_element?(view, "#usage-user-#{nate.id}")
  end

  test "clicking a row opens the user panel and the close link shuts it, keeping the range (scenario 9)", %{
    conn: conn
  } do
    a = insert(:user, name: "Ada")
    board = insert(:board, name: "Pipeline", owner: a)
    first = visit(a, ago: 7200, board_id: board.id, card_refs: ["PI12", "PI14"])
    second = visit(a, ago: 300, board_id: board.id)

    {:ok, view, _html} = live(conn, ~p"/admin/users/usage")

    view |> element("#usage-user-#{a.id}") |> render_click()
    assert_patch(view, "/admin/users/usage?range=30&user=#{a.id}")

    assert has_element?(view, "#usage-panel")

    # The "Visits · 7d" stat is `-visits-7d`: `#usage-panel-visits` is the recent-visits list.
    for id <- ~w(active-days visits-7d time runs shipped waiting) do
      assert has_element?(view, "#usage-panel-stats #usage-panel-#{id}")
    end

    assert has_element?(view, "ul#usage-panel-visits")

    assert view |> attrs("#usage-panel-strip > span[data-state]", "data-state") |> length() == 14
    assert has_element?(view, "ul#usage-panel-visits li#usage-visit-#{first.id}")
    assert has_element?(view, "ul#usage-panel-visits li#usage-visit-#{second.id}")
    assert view |> attrs(~s(ul#usage-panel-visits li[id^="usage-visit-"]), "id") |> length() == 2
    assert text(view, "#usage-visit-#{first.id}") =~ "· PI12 · PI14"
    assert attrs(view, "#usage-panel-billing", "href") == ["/admin/users?user=#{a.id}"]
    assert has_element?(view, "#usage-user-#{a.id}.bg-base-200")

    view |> element("#usage-panel-close") |> render_click()
    assert_patch(view, "/admin/users/usage?range=30")
    refute has_element?(view, "#usage-panel")
  end

  test "a never-seen user shows dashes, sorts last and has an empty visit list (scenario 10)", %{
    conn: conn,
    admin: admin
  } do
    seen = insert(:user, name: "Seen Sam")
    visit(seen, ago: 600)
    visit(admin, ago: 60)
    javier = insert(:user, name: "Javier Ortiz")

    {:ok, view, html} = live(conn, ~p"/admin/users/usage")

    assert text(view, "#usage-user-#{javier.id}-last-seen") == "—"
    assert text(view, "#usage-user-#{javier.id}-time") == "—"
    assert position(html, ~s(id="usage-user-#{javier.id}")) > position(html, ~s(id="usage-user-#{seen.id}"))
    assert position(html, ~s(id="usage-user-#{javier.id}")) > position(html, ~s(id="usage-user-#{admin.id}"))

    {:ok, view, _html} = live(conn, ~p"/admin/users/usage?user=#{javier.id}")
    assert text(view, "#usage-panel-visits-empty") == "No visits yet."
  end

  test "an unparsable or unknown ?user= opens no panel (scenario 11)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users/usage?user=abc")
    refute has_element?(view, "#usage-panel")

    {:ok, view, _html} = live(conn, ~p"/admin/users/usage?user=999999")
    refute has_element?(view, "#usage-panel")
  end

  describe "copy helpers (scenario 12)" do
    test "format_duration/1" do
      assert UsageLive.format_duration(0) == "—"
      assert UsageLive.format_duration(45) == "1m"
      assert UsageLive.format_duration(1320) == "22m"
      assert UsageLive.format_duration(15_000) == "4h 10m"
      assert UsageLive.format_duration(7200) == "2h 0m"
    end

    test "relative_time/2" do
      now = ~U[2026-10-25 15:00:00Z]

      assert UsageLive.relative_time(nil, now) == "—"
      assert UsageLive.relative_time(DateTime.add(now, -30), now) == "just now"
      assert UsageLive.relative_time(DateTime.add(now, -5, :minute), now) == "5m ago"
      assert UsageLive.relative_time(DateTime.add(now, -3, :hour), now) == "3h ago"
      assert UsageLive.relative_time(DateTime.add(now, -30, :hour), now) == "1 day ago"
      assert UsageLive.relative_time(DateTime.add(now, -9, :day), now) == "9 days ago"
    end

    test "today_delta/3" do
      assert UsageLive.today_delta(1, 1, ~D[2026-10-25]) == "same as last Sun"
      assert UsageLive.today_delta(3, 1, ~D[2026-10-25]) == "+2 vs last Sun"
      assert UsageLive.today_delta(0, 1, ~D[2026-10-25]) == "-1 vs last Sun"
    end
  end
end
