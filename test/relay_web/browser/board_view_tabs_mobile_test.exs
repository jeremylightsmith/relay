defmodule RelayWeb.Browser.BoardViewTabsMobileTest do
  @moduledoc """
  Real-browser (Playwright) regression test: the board-view switch
  (`CoreComponents.board_view_tabs/1`) must fit the one-row top bar on a phone.

  RE347 added a third segment ("Value stream"), taking the switch to ~237px of
  `flex:0 0 auto` text. At 390px the header has well under that to spare, so the
  switch spilled over the "Boards" crumb, the board's header actions and the
  account avatar. Nothing scrolled sideways (the header is not the document), so
  only overlapping boxes reveal it — and only a real browser computes those.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  # Every visible header control that the switch must not sit on top of.
  @measure """
  (() => {
    const box = (el) => { const r = el.getBoundingClientRect();
      return {id: el.id || el.getAttribute('aria-label') || el.tagName,
              left: r.left, right: r.right, top: r.top, bottom: r.bottom, w: r.width}; };
    const tabs = document.querySelector('#board-view-tabs');
    const others = [...document.querySelectorAll(
      '#top-bar-logo, #top-bar-crumb a, #top-bar-account, #board-name, ' +
      '#agent-logs-button, #board-settings-link, #restart-stalled-button')]
      .filter((el) => el.offsetParent && el.getBoundingClientRect().width > 0)
      .map(box);
    const t = box(tabs);
    const hits = others.filter((o) =>
      o.left < t.right - 0.5 && t.left < o.right - 0.5 && o.top < t.bottom && t.top < o.bottom);
    const segs = [...tabs.querySelectorAll('a')].map(box);
    const clipped = segs.filter((s) => s.left < t.left - 0.5 || s.right > t.right + 0.5);
    return {hits: hits.map((h) => h.id), clipped: clipped.map((s) => s.id),
            scrollWidth: document.documentElement.scrollWidth,
            clientWidth: document.documentElement.clientWidth};
  })()
  """

  test "the board-view switch fits the top bar at 390px on the board and value stream pages",
       %{conn: conn} do
    conn = conn |> visit("/dev/login") |> assert_has("body .phx-connected") |> assert_has("#board-view-tabs")

    board_path =
      unwrap_value(conn, "window.location.pathname")

    assert_fits(conn, "board")

    conn
    |> visit(board_path <> "/value-stream")
    |> assert_has("body .phx-connected")
    |> assert_has("#board-view-tab-value-stream[aria-current=page]")
    |> assert_fits("value stream")
  end

  defp assert_fits(conn, page) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, m} = Frame.evaluate(frame_id, expression: @measure, timeout: 2_000)

      assert m["hits"] == [],
             "on the #{page} page at 390px the board-view switch overlaps: #{inspect(m["hits"])}"

      assert m["clipped"] == [],
             "on the #{page} page at 390px these switch segments are cut off: #{inspect(m["clipped"])}"

      assert m["scrollWidth"] <= m["clientWidth"] + 1
    end)
  end

  defp unwrap_value(conn, expression) do
    parent = self()

    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:value, value})
    end)

    assert_received {:value, value}
    value
  end
end
