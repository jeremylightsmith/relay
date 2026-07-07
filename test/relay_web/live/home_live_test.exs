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
end
