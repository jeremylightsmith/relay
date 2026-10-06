defmodule RelayWeb.Admin.AdminPagesTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Schemas.Scope

  @paths ["/admin", "/admin/boards", "/admin/users"]

  defp log_in_superadmin(%{conn: conn}) do
    admin = insert(:user, email: hd(Scope.superadmin_emails()))
    %{conn: log_in_user(conn, admin), user: admin}
  end

  defp position(html, needle), do: html |> :binary.match(needle) |> elem(0)

  describe "when logged out" do
    test "every admin page redirects to the sign-in page", %{conn: conn} do
      for path <- @paths do
        assert {:error, {:redirect, %{to: "/"}}} = live(conn, path)
      end
    end
  end

  describe "when logged in as a non-superadmin" do
    setup :register_and_log_in_user

    test "every admin page is denied and redirected", %{conn: conn} do
      for path <- @paths do
        assert {:error, {:redirect, %{to: "/"}}} = live(conn, path)
      end
    end
  end

  describe "/admin as the superadmin" do
    setup :log_in_superadmin

    test "links to Boards, Users and API log", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "h1", "Admin")
      assert has_element?(view, ~s(#admin-page-boards[href="/admin/boards"]), "Boards")
      assert has_element?(view, ~s(#admin-page-users[href="/admin/users"]), "Users")
      assert has_element?(view, ~s(#admin-page-api[href="/admin/api"]), "API log")
    end
  end

  describe "/admin/boards as the superadmin" do
    setup :log_in_superadmin

    test "lists every board A–Z by name with its columns and an Archived badge", %{conn: conn} do
      owner = insert(:user, email: "owner@example.com")

      theirs =
        insert(:board,
          name: "Someone Else's",
          key: "SE",
          owner: owner,
          inserted_at: ~U[2020-01-02 00:00:00Z]
        )

      insert(:membership, board: theirs, user: owner)
      stage = insert(:stage, board: theirs)
      insert(:card, stage: stage)

      archived =
        insert(:board,
          name: "Old Stuff",
          archived_at: ~U[2020-02-01 00:00:00Z],
          inserted_at: ~U[2020-01-01 00:00:00Z]
        )

      {:ok, view, html} = live(conn, ~p"/admin/boards")

      row = "#admin-board-#{theirs.id}"
      assert has_element?(view, row, "Someone Else's")
      assert has_element?(view, row, "SE")
      assert has_element?(view, row, "owner@example.com")
      assert has_element?(view, row, "2020-01-02")
      assert view |> element("#{row}-members") |> render() =~ ~r/>\s*1\s*</
      assert view |> element("#{row}-cards") |> render() =~ ~r/>\s*1\s*</
      refute has_element?(view, "#{row} .badge", "Archived")

      assert has_element?(view, "#admin-board-#{archived.id}", "Old Stuff")
      assert has_element?(view, "#admin-board-#{archived.id} .badge", "Archived")

      assert position(html, "admin-board-#{archived.id}") < position(html, "admin-board-#{theirs.id}")
      refute has_element?(view, "[id^=board-star-]")
      assert has_element?(view, ~s(#admin-back[href="/admin"]))
    end

    test "links a board name only when the superadmin is a member", %{conn: conn, user: admin} do
      mine = insert(:board, name: "Mine", slug: "admin-mine")
      insert(:membership, board: mine, user: admin)
      theirs = insert(:board, name: "Theirs", slug: "admin-theirs")

      {:ok, view, _html} = live(conn, ~p"/admin/boards")

      assert has_element?(view, ~s(#admin-board-#{mine.id} a[href="/board/admin-mine"]), "Mine")
      assert has_element?(view, "#admin-board-#{theirs.id}", "Theirs")
      refute has_element?(view, "#admin-board-#{theirs.id} a")
    end
  end

  describe "/admin/users as the superadmin" do
    setup :log_in_superadmin

    test "lists every user newest first with provider, board count and created date", %{
      conn: conn,
      user: admin
    } do
      grace =
        insert(:user,
          name: "Grace Hopper",
          email: "grace@example.com",
          provider: "google",
          inserted_at: ~U[2020-03-04 00:00:00Z]
        )

      insert(:membership, user: grace)

      {:ok, view, html} = live(conn, ~p"/admin/users")

      row = "#admin-user-#{grace.id}"
      assert has_element?(view, row, "Grace Hopper")
      assert has_element?(view, row, "grace@example.com")
      assert has_element?(view, row, "google")
      assert has_element?(view, row, "2020-03-04")
      assert view |> element("#{row}-boards") |> render() =~ ~r/>\s*1\s*</

      # the superadmin was inserted "now", so it sorts before grace (2020)
      assert position(html, "admin-user-#{admin.id}") < position(html, "admin-user-#{grace.id}")
      assert has_element?(view, ~s(#admin-back[href="/admin"]))
    end
  end
end
