defmodule HamacaWeb.Browser.BoardSmokeTest do
  @moduledoc """
  Real-browser (Playwright) smoke test that guards the `browser-tests` CI job.

  Kept to a single robust assertion path: sign in via the dev bypass, land on
  the board, wait for LiveView to connect, and confirm a seeded stage renders.
  This is the CI gate, not a full user journey.
  """
  use PhoenixTest.Playwright.Case, async: true

  alias Hamaca.Accounts
  alias Hamaca.Boards

  @moduletag :playwright

  # RE470: `/board` no longer seeds a board — a boardless user lands on the `/boards` first-run
  # picker — so the dev user needs a board for `/dev/login` to land on one.
  setup do
    _board = Boards.get_or_create_default_board(Accounts.ensure_dev_user!())
    :ok
  end

  test "signs in and renders the board with a seeded stage", %{conn: conn} do
    conn
    # /dev/login logs in the fixed dev user and redirects to /board.
    |> visit("/dev/login")
    |> assert_has("#top-bar")
    # Wait for the LiveView socket to connect before asserting on live content.
    |> assert_has("body .phx-connected")
    |> assert_has("h3", text: "Backlog")
  end
end
