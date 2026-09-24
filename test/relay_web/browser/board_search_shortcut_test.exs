defmodule RelayWeb.Browser.BoardSearchShortcutTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE342: `/` on the board (and the story map) moves focus into
  the header search box, without typing the `/`.

  The shortcut is a `window` keydown listener in the `BoardSearchInput` hook, so
  `Phoenix.LiveViewTest` never runs it — only real keystrokes in a real browser can see where
  `document.activeElement` ends up. Same reasoning as `RelayWeb.Browser.TypingKeyGuardTest`.

  The viewport is pinned at 1440px: the box is `hidden lg:block` on the board and `hidden xl:block`
  on the story map (RE198), and below those widths `/` deliberately does nothing.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 1440, height: 900}]

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Shortcut target card"})

    %{board: board, card: card, ref: Cards.ref(board, card)}
  end

  test "/ on the page focuses the empty search box, and typing then searches", ctx do
    ctx.conn
    |> visit_page("/board/#{ctx.board.slug}")
    |> press_on("body", "/")
    |> assert_search_focused()
    |> assert_search_value("")
    |> type_into_search("Shortcut tar")
    |> assert_has("#board-search-result-#{ctx.ref}")
  end

  test "/ typed inside the search box is a literal character", ctx do
    ctx.conn
    |> visit_page("/board/#{ctx.board.slug}")
    |> type_into_search("a/b")
    |> assert_search_value("a/b")
  end

  test "/ does nothing while the card drawer is open", ctx do
    ctx.conn
    |> visit_page("/board/#{ctx.board.slug}?card=#{ctx.ref}")
    |> assert_has("#card-drawer-panel")
    # The Detail tab is a button, not an editable field, so the editable-field guard does not
    # apply here. Only the drawer guard can keep focus off the search box.
    |> press_on("#card-drawer-tab-detail", "/")
    |> assert_has("#card-drawer-panel")
    |> unwrap(fn %{frame_id: frame_id} ->
      # The keydown handler is synchronous, so focus has settled by the time press returns.
      refute focused_id(frame_id) == "board-search-input",
             "/ moved focus to the board search box behind the open drawer"
    end)
    |> assert_search_value("")
  end

  test "/ focuses the search box on the story map too", ctx do
    ctx.conn
    |> visit_page("/board/#{ctx.board.slug}/story-map")
    |> assert_has("#story-map")
    |> press_on("body", "/")
    |> assert_search_focused()
    |> assert_search_value("")
  end

  defp visit_page(conn, path) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit(path)
    # The hook's window listener only exists once THIS page's socket has mounted it; a key
    # pressed earlier is simply lost (see TypingKeyGuardTest).
    |> assert_has("body .phx-connected")
  end

  defp press_on(session, selector, key) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.press(frame_id, selector: selector, key: key, timeout: 2_000)
    end)
  end

  defp type_into_search(session, text) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: "#board-search-input", text: text, timeout: 2_000)
    end)
  end

  defp assert_search_focused(session) do
    unwrap(session, fn %{frame_id: frame_id} ->
      assert focused_id(frame_id) == "board-search-input",
             "expected focus on #board-search-input, got #{inspect(focused_id(frame_id))}"
    end)
  end

  defp assert_search_value(session, expected) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.input_value(frame_id, selector: "#board-search-input", timeout: 2_000)
      assert value == expected
    end)
  end

  defp focused_id(frame_id) do
    {:ok, id} =
      Frame.evaluate(frame_id,
        expression: "(() => document.activeElement && document.activeElement.id)()",
        timeout: 2_000
      )

    id
  end
end
