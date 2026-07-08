defmodule RelayWeb.Browser.BoardSmokeTest do
  @moduledoc """
  Real-browser (Playwright) smoke test that guards the `browser-tests` CI job.

  Kept to a single robust assertion path: sign in via the dev bypass, land on
  the board, wait for LiveView to connect, and confirm a seeded stage renders.
  This is the CI gate, not a full user journey.
  """
  use PhoenixTest.Playwright.Case, async: true

  @moduletag :playwright

  test "signs in and renders the board with a seeded stage", %{conn: conn} do
    conn
    # /dev/login logs in the fixed dev user and redirects to /board.
    |> visit("/dev/login")
    |> assert_has("#board-title")
    # Wait for the LiveView socket to connect before asserting on live content.
    |> assert_has("body .phx-connected")
    |> assert_has("h3", text: "Backlog")
  end
end
