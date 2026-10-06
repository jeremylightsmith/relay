defmodule RelayWeb.Browser.EmbedBoardHeaderTest do
  @moduledoc """
  Real-browser (Playwright) test for RE393 · card mockup "Board tab — web large-title
  header at iOS sizes": embedded (`?embed=1`) at 390×844 the Board tab renders the iOS
  large-title header, 36px chips and mobile-scale stage and card faces — all scoped
  under `main[data-embed]`, so desktop web keeps its sizes. Only a real browser proves
  the `!important` embed rules beat the inline `style=` font sizes.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  # The default board's first pager page is Backlog; make sure it shows card faces.
  defp board_with_a_card do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    {:ok, backlog} = Boards.update_stage(backlog, %{collapsed_by_default: false})
    {:ok, _} = Cards.create_card(backlog, %{title: "Embed type scale card"})
    {board, backlog}
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

  defp visit_embedded(conn, board) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?embed=1")
    |> assert_has("body .phx-connected")
    |> assert_has("main[data-embed] #board-create-card")
  end

  test "the embedded header is an iOS large title with a 44px + and 36px chips", %{conn: conn} do
    {board, _backlog} = board_with_a_card()
    conn = visit_embedded(conn, board)

    m =
      measure(conn, """
      (() => {
        const title = document.querySelector('#board-switch-board .board-pager-title');
        const plus = document.querySelector('#board-create-card').getBoundingClientRect();
        const chip = document.querySelector('.board-pager-chip');
        // The chip's label is its own text node, so the chip's font is the label's.
        const label = chip;
        const count = document.querySelector('.board-pager-chip-count');
        return {
          titleSize: getComputedStyle(title).fontSize,
          titleWeight: getComputedStyle(title).fontWeight,
          plusW: plus.width, plusH: plus.height,
          chipH: chip.getBoundingClientRect().height,
          labelSize: getComputedStyle(label).fontSize,
          countSize: getComputedStyle(count).fontSize,
          countFamily: getComputedStyle(count).fontFamily
        };
      })()
      """)

    assert m["titleSize"] == "34px", inspect(m)
    assert m["titleWeight"] == "700", inspect(m)
    assert m["plusW"] == 44 and m["plusH"] == 44, inspect(m)
    assert m["chipH"] == 36, inspect(m)
    assert m["labelSize"] == "15px", inspect(m)
    assert m["countSize"] == "13px", inspect(m)
    assert m["countFamily"] =~ "JetBrains Mono", inspect(m)
  end

  test "the first embedded stage page uses the mobile scale for stage and card faces",
       %{conn: conn} do
    {board, backlog} = board_with_a_card()
    col = "stage-col-#{backlog.position}"

    conn =
      conn
      |> visit_embedded(board)
      |> assert_has("##{col}-show-as-list")
      |> assert_has("##{col} .card-title", text: "Embed type scale card")

    m =
      measure(conn, """
      (() => {
        const col = document.querySelector('##{col}');
        const name = col.querySelector('.stage-name');
        const list = document.querySelector('##{col}-show-as-list');
        const title = col.querySelector('.card-title');
        const ref = col.querySelector('.card-ref');
        return {
          nameSize: getComputedStyle(name).fontSize,
          listH: list.getBoundingClientRect().height,
          listSize: getComputedStyle(list).fontSize,
          titleSize: getComputedStyle(title).fontSize,
          titleWeight: getComputedStyle(title).fontWeight,
          refSize: getComputedStyle(ref).fontSize
        };
      })()
      """)

    assert m["nameSize"] == "17px", inspect(m)
    assert m["listH"] >= 44, inspect(m)
    assert m["listSize"] == "15px", inspect(m)
    assert m["titleSize"] == "16px", inspect(m)
    assert m["titleWeight"] == "600", inspect(m)
    assert m["refSize"] == "13px", inspect(m)
  end

  @tag browser_context_opts: [viewport: %{width: 1440, height: 900}]
  test "desktop web (?embed=0) is untouched by the embed scale", %{conn: conn} do
    {board, _backlog} = board_with_a_card()

    conn =
      conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit("/board/#{board.slug}?embed=0")
      |> assert_has("body .phx-connected")
      |> assert_has("#top-bar")
      |> assert_has(".card-title", text: "Embed type scale card")

    m =
      measure(conn, """
      (() => ({
        embedMains: document.querySelectorAll('main[data-embed]').length,
        titleSize: getComputedStyle(document.querySelector('.card-title')).fontSize
      }))()
      """)

    assert m["embedMains"] == 0, inspect(m)
    assert m["titleSize"] == "12.5px", inspect(m)
  end

  test "dark theme: the + takes the dark theme's primary token, not a light literal",
       %{conn: conn} do
    {board, _backlog} = board_with_a_card()

    conn =
      conn
      |> visit_embedded(board)
      |> tap(&measure(&1, "localStorage.setItem('phx:theme', 'dark')"))
      |> visit("/board/#{board.slug}?embed=1")
      |> assert_has("body .phx-connected")
      |> assert_has("html[data-theme=dark]")
      |> assert_has("main[data-embed] #board-create-card")

    m =
      measure(conn, """
      (() => {
        const probe = document.createElement('div');
        probe.style.background = 'var(--color-primary)';
        document.querySelector('main').appendChild(probe);
        const primary = getComputedStyle(probe).backgroundColor;
        probe.remove();
        return {
          theme: document.documentElement.getAttribute('data-theme'),
          primary: primary,
          plus: getComputedStyle(document.querySelector('#board-create-card')).backgroundColor
        };
      })()
      """)

    assert m["theme"] == "dark", inspect(m)
    assert m["plus"] == m["primary"], inspect(m)
  end
end
