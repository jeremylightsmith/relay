defmodule RelayWeb.PageControllerTest do
  use RelayWeb.ConnCase, async: true

  describe "GET / when logged out" do
    test "renders the sign-in page with a Google button", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ "Sign in with Google"
      assert html =~ "id=\"google-signin\""
      assert html =~ ~p"/auth/google"
    end
  end

  describe "GET / when logged in" do
    setup :register_and_log_in_user

    test "redirects to the app home", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/home"
    end
  end
end
