defmodule RelayWeb.Browser.BoardsStarTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE395's star on the `/boards` tiles. The star button is a
  sibling of the tile's stretched link, stacked above it, so a click on the star toggles the
  star without navigating, while a click anywhere else on the tile (the name text) still opens
  the board. `Phoenix.LiveViewTest` fires `phx-click` regardless of DOM nesting or stacking, so
  only a real browser can tell which element actually receives the click.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Relay.Accounts
  alias Relay.Boards

  @moduletag :playwright

  setup do
    user = Accounts.ensure_dev_user!()
    suffix = System.unique_integer([:positive])

    boards =
      for name <- ["zeta", "Alpha", "mango"], into: %{} do
        {:ok, board} =
          Boards.create_board(user, %{name: "#{name} #{suffix}", slug: "#{String.downcase(name)}-star-#{suffix}"})

        {name, board}
      end

    %{boards: boards}
  end

  test "clicking a tile's star stars it without leaving /boards", %{conn: conn, boards: boards} do
    zeta = boards["zeta"]

    conn
    |> visit_boards()
    |> click("#board-star-#{zeta.slug}")
    |> assert_has(~s(#board-star-#{zeta.slug}[aria-pressed="true"]))
    |> assert_path("/boards")
  end

  test "clicking a board's name text opens the board", %{conn: conn, boards: boards} do
    alpha = boards["Alpha"]

    conn
    |> visit_boards()
    |> click("#board-card-#{alpha.slug}", alpha.name)
    |> assert_path("/board/#{alpha.slug}")
  end

  defp visit_boards(conn) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/boards")
    |> assert_has("body .phx-connected")
  end
end
