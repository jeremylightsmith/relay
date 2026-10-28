defmodule HamacaWeb.Browser.BoardBarTest do
  @moduledoc """
  Real-browser (Playwright) test for RE497's one quiet board bar: **logo · board name ▾ · [view
  switch, `sm`+] · … · search (wide only) · stalled · ⋯ · avatar**.

  At 390px only a real browser computes whether the bar's boxes overflow, overlap or shrink below
  a 44px target — and only real clicks and keystrokes run the menus' client-side `JS.toggle` /
  `JS.hide` (`phx-click-away`, `phx-window-keydown`), which `Phoenix.LiveViewTest` never executes.
  At 1280px it proves the wide bar's order, its ⋯ items and the borderless search's `/` + Escape.

  Replaces RE347's `BoardViewTabsMobileTest`, which measured a phone view switch that no longer
  renders below `sm`.
  """
  use PhoenixTest.Playwright.Case, async: false

  import Hamaca.Factory

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  # The five controls the phone bar must fit side by side.
  @controls ~w(#top-bar-logo #board-switcher-button #restart-stalled-button #board-more-button #top-bar-account)

  # The default board is "My board" (~67px at 15px), narrower than the 80px readability floor on
  # its own, so give it a realistic name long enough that only squeezing could take it below 80.
  setup do
    board = Boards.get_or_create_default_board(Accounts.ensure_dev_user!())
    {:ok, _} = Boards.update_board(board, %{name: "Hamaca product roadmap"})
    %{board: Boards.get_or_create_default_board(Accounts.ensure_dev_user!())}
  end

  describe "at 390px" do
    setup %{board: board} do
      stall_a_card(board)
      :ok
    end

    test "the bar fits one row with the stalled control present", %{conn: conn, board: board} do
      conn = conn |> visit_board(board) |> assert_has("#restart-stalled-button")

      m =
        measure(conn, """
        (() => {
          const ids = #{Jason.encode!(@controls)};
          const box = (sel) => { const r = document.querySelector(sel).getBoundingClientRect();
            return {sel, left: r.left, right: r.right, top: r.top, bottom: r.bottom,
                    w: r.width, h: r.height}; };
          const boxes = ids.map(box);
          const overlaps = [];
          for (let i = 0; i < boxes.length; i++)
            for (let j = i + 1; j < boxes.length; j++) {
              const a = boxes[i], b = boxes[j];
              if (a.left < b.right - 0.5 && b.left < a.right - 0.5 &&
                  a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5) overlaps.push([a.sel, b.sel]);
            }
          const hidden = (sel) => document.querySelector(sel).offsetParent === null;
          return {
            barH: document.querySelector('#top-bar').getBoundingClientRect().height,
            nameW: document.querySelector('#board-name').getBoundingClientRect().width,
            innerWidth: window.innerWidth,
            rights: Object.fromEntries(['#restart-stalled-button', '#board-more-button', '#user-avatar']
              .map((s) => [s, box(s).right])),
            overlaps,
            short: boxes.filter((b) => b.h < 44).map((b) => [b.sel, b.h]),
            scrollWidth: document.documentElement.scrollWidth,
            clientWidth: document.documentElement.clientWidth,
            tabsHidden: hidden('#board-view-tabs'),
            searchHidden: hidden('#board-search')
          };
        })()
        """)

      assert m["barH"] == 53, inspect(m)
      assert m["nameW"] >= 80, "the board name is squeezed below 80px: #{inspect(m)}"

      for {sel, right} <- m["rights"] do
        assert right <= m["innerWidth"], "#{sel} is cut off at 390px: #{inspect(m)}"
      end

      assert m["overlaps"] == [], "bar controls overlap at 390px: #{inspect(m["overlaps"])}"
      assert m["scrollWidth"] <= m["clientWidth"] + 1, inspect(m)
      assert m["tabsHidden"], "#board-view-tabs should not render on a phone"
      assert m["searchHidden"], "#board-search should not render on a phone"
      assert m["short"] == [], "bar targets under 44px tall: #{inspect(m["short"])}"
    end

    test "the board switcher opens with the current board checked, and Escape closes it",
         %{conn: conn, board: board} do
      conn
      |> visit_board(board)
      |> refute_has("#board-switcher-menu")
      |> click("#board-switcher-button")
      |> assert_has("#board-switcher-menu")
      |> assert_has("#board-switcher-all-boards")
      # The rows arrive over the LiveComponent's "load" round-trip; assert_has waits for them.
      |> assert_has("#board-switcher-row-#{board.slug}[aria-current=page]")
      |> press("body", "Escape")
      |> refute_has("#board-switcher-menu")
    end

    test "⋯ holds the views on a phone, not the Agent log, and a view navigates",
         %{conn: conn, board: board} do
      conn
      |> visit_board(board)
      |> refute_has("#board-more-menu")
      |> click("#board-more-button")
      |> assert_has("#board-more-menu")
      |> assert_has("#board-more-view-story-map")
      |> refute_has("#board-more-agent-log")
      |> click("#board-more-view-story-map")
      |> assert_path("/board/#{board.slug}/story-map")
    end

    test "clicking the board body closes the ⋯ menu", %{conn: conn, board: board} do
      conn
      |> visit_board(board)
      |> click("#board-more-button")
      |> assert_has("#board-more-menu")
      |> click_at(195, 500)
      |> refute_has("#board-more-menu")
    end
  end

  describe "at 1280px" do
    @describetag browser_context_opts: [viewport: %{width: 1280, height: 800}]

    test "the wide bar shows the view switch and a borderless search, in order",
         %{conn: conn, board: board} do
      conn =
        conn
        |> visit_board(board)
        |> assert_has("#board-view-tabs")
        |> assert_has("#board-search-input")

      m =
        measure(conn, """
        (() => {
          const order = ['#board-switcher-button', '#board-view-tabs', '#board-search',
                         '#board-more-button', '#top-bar-account'];
          const input = document.querySelector('#board-search-input');
          return {
            lefts: order.map((s) => document.querySelector(s).getBoundingClientRect().left),
            inBase200: input.closest('.bg-base-200') !== null
          };
        })()
        """)

      assert m["inBase200"], "#board-search-input should sit in a bg-base-200 field"
      assert m["lefts"] == Enum.sort(m["lefts"]), "bar order is wrong: #{inspect(m["lefts"])}"
    end

    test "⋯ offers the Agent log, not the phone's views, and opening it closes the menu",
         %{conn: conn, board: board} do
      conn
      |> visit_board(board)
      |> click("#board-more-button")
      |> assert_has("#board-more-agent-log")
      |> refute_has("#board-more-view-board")
      |> click("#board-more-agent-log")
      |> assert_has("#agent-log-sheet")
      |> refute_has("#board-more-menu")
    end

    test "/ focuses the search, typing finds a card, Escape clears it",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, card} = Cards.create_card(code, %{title: "Bar search probe"})
      ref = Cards.ref(board, card)

      conn
      |> visit_board(board)
      |> press("body", "/")
      |> unwrap(fn %{frame_id: frame_id} ->
        assert focused_id(frame_id) == "board-search-input"
      end)
      |> type("#board-search-input", "Bar search")
      |> assert_has("#board-search-result-#{ref}")
      |> press("#board-search-input", "Escape")
      |> refute_has("#board-search-results")
      |> unwrap(fn %{frame_id: frame_id} ->
        {:ok, value} = Frame.input_value(frame_id, selector: "#board-search-input", timeout: 2_000)
        assert value == ""
      end)
    end
  end

  # A card whose latest run failed cleanly — `Runs.stalled_cards/1` counts it, so the bar carries
  # `#restart-stalled-button` (the phone bar's worst case).
  defp stall_a_card(board) do
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    {:ok, card} = Cards.create_card(spec, %{title: "Stalled bar probe"})
    run = insert(:run, card: card, status: :failed, current_node: nil, flow_id: nil)
    insert(:node_execution, run: run, node_key: "brainstorm", outcome: :failed)
  end

  defp visit_board(conn, board) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}")
    # JS commands and window key listeners only exist once THIS page's socket has mounted.
    |> assert_has("body .phx-connected")
    |> assert_has("#board-more-button")
  end

  # A real mouse click at viewport coordinates — on the board body, away from every menu.
  defp click_at(conn, x, y) do
    unwrap(conn, fn %{page_id: page_id} ->
      {:ok, _} = Page.mouse_move(page_id, x: x, y: y, timeout: 2_000)
      {:ok, _} = Page.mouse_down(page_id, timeout: 2_000)
      {:ok, _} = Page.mouse_up(page_id, timeout: 2_000)
    end)
  end

  # Evaluates a JS expression in the page and returns its value.
  defp measure(conn, expression) do
    parent = self()

    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:measured, value})
    end)

    assert_received {:measured, value}
    value
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
