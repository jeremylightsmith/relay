defmodule HamacaWeb.Browser.DependencyChipLinkTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE474. A dependency chip is an `<a href phx-click="select_card">`:
  left alone, the browser would follow the `href` (a full page load) while LiveView pushes
  `select_card`. The `.DependencyChipLink` hook prevents the default on a plain click so only the
  LiveView patch happens. `Phoenix.LiveViewTest` never runs hooks, so only a real browser can prove
  the page did not reload — a `window` marker set before the click must survive it.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards

  @moduletag :playwright

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))

    {:ok, blocker_card} = Cards.create_card(code, %{title: "Blocker"})
    {:ok, dependent_card} = Cards.create_card(code, %{title: "Dependent"})
    blocker = Cards.ref(board, blocker_card)
    dependent = Cards.ref(board, dependent_card)
    {:ok, _} = Cards.set_dependencies(board, dependent_card, [blocker])

    %{board: board, blocker: blocker, dependent: dependent}
  end

  test "clicking a blocker chip opens the blocker in the drawer without a page reload", ctx do
    ctx.conn
    |> open_drawer(ctx.board, ctx.dependent)
    |> evaluate("window.__re474_marker = 1")
    |> click("#card-drawer-blocked-by-link-#{ctx.blocker}")
    |> assert_path("/board/#{ctx.board.slug}", query_params: %{"card" => ctx.blocker})
    |> assert_has("#card-drawer-blocks-#{ctx.dependent}")
    |> evaluate("window.__re474_marker", fn marker ->
      assert marker == 1, "the page reloaded: the window marker is #{inspect(marker)}"
    end)
  end

  test "✕ removes the blocker and leaves the drawer on the dependent", ctx do
    ctx.conn
    |> open_drawer(ctx.board, ctx.dependent)
    |> click("#card-drawer-blocked-by-remove-#{ctx.blocker}")
    |> refute_has("#card-drawer-blocked-by-#{ctx.blocker}")
    |> assert_path("/board/#{ctx.board.slug}", query_params: %{"card" => ctx.dependent})
  end

  defp open_drawer(conn, board, ref) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{ref}")
    # Wait for THIS page's socket, then for the async-loaded drawer rail: the link only exists
    # once connected, so its hook is mounted by the time we click it.
    |> assert_has("body .phx-connected")
    |> assert_has("#card-drawer-blocked-by .dependency-chip")
  end
end
