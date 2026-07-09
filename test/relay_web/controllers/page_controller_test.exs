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

    test "redirects to the board", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/board"
    end
  end

  describe "public legal pages" do
    test "GET /privacy renders the privacy policy", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)
      assert html =~ "Privacy Policy"
      assert html =~ "Google Sign-In"
    end

    test "GET /terms renders the terms of service", %{conn: conn} do
      html = conn |> get(~p"/terms") |> html_response(200)
      assert html =~ "Terms of Service"
    end

    test "the sign-in page links to terms and privacy", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~p"/terms"
      assert html =~ ~p"/privacy"
    end

    test "the sign-in page links to the API docs", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~p"/docs"
    end
  end
end
