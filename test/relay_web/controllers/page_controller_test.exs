defmodule RelayWeb.PageControllerTest do
  use RelayWeb.ConnCase, async: true

  describe "GET / when logged out" do
    test "renders the landing page hero with the branded Google button", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      # branded Google sign-in CTA (kept from the old sign-in card)
      assert html =~ "Sign in with Google"
      assert html =~ "id=\"google-signin\""
      assert html =~ ~p"/auth/google"

      # hero copy from the artboard
      assert html =~ "Pass work between people and AI"
      assert html =~ "HUMAN + AI, ONE BOARD"

      # nav "Open the board" CTA and the secondary "See how it works" ghost button
      assert html =~ "Open the board"
      assert html =~ "See how it works"
    end

    test "titles the landing tab with the · Relay suffix and drops the Phoenix suffix", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "AI-first kanban board · Relay"
      refute html =~ "Phoenix Framework"
      refute html =~ "Relay · Relay"
    end

    test "renders the marketing body sections and anchors", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # section anchors the nav links target
      assert html =~ "id=\"how\""
      assert html =~ "id=\"flow\""
      assert html =~ "id=\"stages\""

      # representative headings from each section
      assert html =~ "Every stage has an owner"
      assert html =~ "A question, not a wrong guess"
      assert html =~ "Watch a card relay across the board"
      assert html =~ "Shape the stages around how you actually work"
      assert html =~ "Give the AI a lane"

      # responsive + fidelity signals
      assert html =~ "md:grid-cols-3"
      assert html =~ "overflow-x-auto"
      # the CTA band is a deliberately fixed-dark panel in both themes
      assert html =~ "background:oklch(0.22 0.02 255)"
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
