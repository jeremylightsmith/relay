defmodule RelayWeb.HomeLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "when logged out" do
    test "GET /home redirects to the sign-in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/home")
    end
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    test "shows the signed-in stub with the user's name", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/home")

      assert has_element?(view, "#home-stub")
      assert render(view) =~ user.name
    end
  end

  describe "top bar" do
    test "shows the avatar image and a sign out link", %{conn: conn} do
      user = insert(:user, avatar_url: "https://example.com/me.png")
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/home")

      assert has_element?(view, "#user-avatar img")
      assert has_element?(view, "#sign-out")
    end

    test "falls back to initials when the user has no avatar image", %{conn: conn} do
      user = insert(:user, avatar_url: nil, name: "Ada Lovelace")
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/home")

      refute has_element?(view, "#user-avatar img")
      assert has_element?(view, "#user-avatar", "AL")
    end
  end

  describe "signing out" do
    test "after sign out, the home route requires signing in again", %{conn: conn} do
      user = insert(:user)
      conn = conn |> log_in_user(user) |> delete(~p"/logout")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/home")
    end
  end
end
