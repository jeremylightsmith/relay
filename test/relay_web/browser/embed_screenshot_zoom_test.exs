defmodule RelayWeb.Browser.EmbedScreenshotZoomTest do
  @moduledoc """
  Real-browser (Playwright) test for RE405 — the embedded (native app) viewer's screenshots: a
  PNG fits the frame width, zooms with − · Fit · + and a two-finger pinch (1×–4×), pans with one
  finger (the frame box scrolls both ways), and never pages by swipe. Only a real browser lays the
  image out and runs the colocated `.MockupRenderWidth` / `.MockupSwipe` hooks.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  # The suite-wide Playwright ceiling (config/test.exs) — a hand-rolled 5s wait flaked under
  # full-suite load while the image was still fetching/decoding.
  @wait_timeout :phoenix_test |> Application.compile_env!(:playwright) |> Keyword.fetch!(:timeout)

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Embedded screenshots"})

    {:ok, card} =
      Cards.update_ai_result(card, %{
        "summary" => "Built it",
        "screens" => [
          %{"url" => "/images/logo_dark_512.png", "caption" => "Big"},
          %{"url" => "/images/logo_light_128.png", "caption" => "Small"}
        ]
      })

    %{board: board, ref: Cards.ref(board, card)}
  end

  defp measure(conn, expression) do
    parent = self()

    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:measured, value})
    end)

    assert_received {:measured, value}
    value
  end

  # Card mode renders only fixed overlays, so wait for attachment rather than visibility.
  defp await_attached(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.wait_for_selector(frame_id, selector: selector, state: "attached", timeout: @wait_timeout)
    end)
  end

  defp await_connected(conn), do: await_attached(conn, "[data-phx-main].phx-connected")

  defp await_image(conn) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.wait_for_function(frame_id,
          expression:
            "(() => { const i = document.querySelector('#mockup-viewer-image'); return i && i.complete && i.naturalWidth > 0 })()",
          timeout: @wait_timeout
        )
    end)
  end

  defp visit_viewer(conn, ctx) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/cards/#{ctx.ref}?board=#{ctx.board.slug}&embed=1&back=Board&screenshot=1")
    |> await_connected()
    |> assert_has("#mockup-viewer-pager-count", text: "1 of 2")
    |> await_image()
  end

  # The zoom control, the frame box's scroll geometry and the image's rendered width. `fit` is
  # min(naturalWidth, box.clientWidth), measured in the page.
  defp state(conn, scroll_left \\ nil) do
    measure(conn, """
    (() => {
      const box = document.querySelector('[id^="mockup-viewer-frame-box-"]');
      const img = document.querySelector('#mockup-viewer-image');
      #{if scroll_left, do: "box.scrollLeft = #{scroll_left};", else: ""}
      return {
        box: box.id,
        zoom: box.dataset.zoom,
        scrollWidth: box.scrollWidth,
        clientWidth: box.clientWidth,
        scrollLeft: box.scrollLeft,
        boxLeft: box.getBoundingClientRect().left,
        imgWidth: img.getBoundingClientRect().width,
        transform: getComputedStyle(img).transform,
        fit: Math.min(img.naturalWidth, box.clientWidth),
        label: document.querySelector('#mockup-viewer-zoom-reset').textContent.trim(),
        outDisabled: document.querySelector('#mockup-viewer-zoom-out').disabled,
        inDisabled: document.querySelector('#mockup-viewer-zoom-in').disabled,
        search: window.location.search
      };
    })()
    """)
  end

  defp zoom_to(conn, label, clicks) do
    conn = Enum.reduce(1..clicks//1, conn, fn _, c -> click(c, "#mockup-viewer-zoom-in") end)
    assert_has(conn, "#mockup-viewer-zoom-reset", text: label)
  end

  @swipe_left """
  (() => {
    const main = document.querySelector('#mockup-viewer-main');
    const touch = (x) => new Touch({identifier: 1, target: main, clientX: x, clientY: 400});
    main.dispatchEvent(new TouchEvent('touchstart', {touches: [touch(300)], changedTouches: [touch(300)], bubbles: true}));
    main.dispatchEvent(new TouchEvent('touchend', {touches: [], changedTouches: [touch(150)], bubbles: true}));
    return true;
  })()
  """

  # A two-finger pinch on the frame box, horizontal around x = 195: fingers start `from` px apart
  # and end `to` px apart. Returns whether the touchmove was default-prevented.
  defp pinch(conn, from, to) do
    measure(conn, """
    (() => {
      const box = document.querySelector('[id^="mockup-viewer-frame-box-"]');
      const t = (id, x) => new Touch({identifier: id, target: box, clientX: x, clientY: 400});
      const pair = (d) => [t(1, 195 - d / 2), t(2, 195 + d / 2)];
      const start = pair(#{from});
      box.dispatchEvent(new TouchEvent('touchstart', {touches: start, targetTouches: start, changedTouches: start, bubbles: true, cancelable: true}));
      const moved = pair(#{to});
      const move = new TouchEvent('touchmove', {touches: moved, targetTouches: moved, changedTouches: moved, bubbles: true, cancelable: true});
      box.dispatchEvent(move);
      box.dispatchEvent(new TouchEvent('touchend', {touches: [], targetTouches: [], changedTouches: moved, bubbles: true, cancelable: true}));
      return move.defaultPrevented;
    })()
    """)
  end

  test "6. at Fit the screenshot fills the frame width, − disabled, no sideways scroll", %{conn: conn} = ctx do
    s = conn |> visit_viewer(ctx) |> state()

    assert s["label"] == "Fit", inspect(s)
    assert s["outDisabled"], inspect(s)
    assert s["zoom"] == "1", inspect(s)
    assert_in_delta s["imgWidth"], s["clientWidth"], 1
    assert s["scrollWidth"] == s["clientWidth"], inspect(s)
  end

  test "7. + zooms to 150% by width (no transform) and the box pans sideways", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> zoom_to("150%", 1)
    s = state(conn)

    assert s["label"] == "150%"
    assert s["zoom"] == "1.5"
    assert s["transform"] == "none", inspect(s)
    assert_in_delta s["imgWidth"], 1.5 * s["fit"], 1
    assert s["scrollWidth"] > s["clientWidth"], inspect(s)
    assert state(conn, 100)["scrollLeft"] == 100
  end

  test "8. the reset button returns from 200% to Fit", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> zoom_to("200%", 2) |> click("#mockup-viewer-zoom-reset")
    conn = assert_has(conn, "#mockup-viewer-zoom-reset", text: "Fit")
    s = state(conn)

    assert s["label"] == "Fit"
    assert s["outDisabled"]
    assert_in_delta s["imgWidth"], s["fit"], 1
  end

  test "9. at Fit a leftward swipe never pages a screenshot", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)
    measure(conn, @swipe_left)
    # Give a (wrong) mockup_next push time to round-trip before checking it never happened.
    Process.sleep(500)

    conn = assert_has(conn, "#mockup-viewer-pager-count", text: "1 of 2")
    assert state(conn)["search"] =~ "screenshot=1"
  end

  test "10. zoomed to 150% the same swipe stays put and keeps the zoom", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> zoom_to("150%", 1)
    measure(conn, @swipe_left)
    Process.sleep(500)

    conn = assert_has(conn, "#mockup-viewer-pager-count", text: "1 of 2")
    s = state(conn)
    assert s["search"] =~ "screenshot=1"
    assert s["label"] == "150%"
  end

  test "11. the pager's next resets to Fit and a narrow image is never upscaled", %{conn: conn} = ctx do
    conn =
      conn
      |> visit_viewer(ctx)
      |> zoom_to("150%", 1)
      |> click("#mockup-viewer-pager-next")
      |> assert_has("#mockup-viewer-pager-count", text: "2 of 2")
      |> await_image()
      |> assert_has("#mockup-viewer-zoom-reset", text: "Fit")

    s = state(conn)
    assert s["search"] =~ "screenshot=2"
    assert s["label"] == "Fit"
    assert s["imgWidth"] == 128, inspect(s)
  end

  test "12. a two-finger pinch zooms around its midpoint and blocks the native gesture", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)
    assert pinch(conn, 100, 200) == true

    s = state(conn)
    assert s["label"] == "200%", inspect(s)
    assert_in_delta s["imgWidth"], 2 * s["fit"], 2
    assert_in_delta s["scrollLeft"], 195 - s["boxLeft"], 20
  end

  test "13. a one-finger drag is left to native scrolling", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)

    prevented =
      measure(conn, """
      (() => {
        const box = document.querySelector('[id^="mockup-viewer-frame-box-"]');
        const t = (x) => [new Touch({identifier: 1, target: box, clientX: x, clientY: 400})];
        box.dispatchEvent(new TouchEvent('touchstart', {touches: t(200), changedTouches: t(200), bubbles: true, cancelable: true}));
        const move = new TouchEvent('touchmove', {touches: t(150), changedTouches: t(150), bubbles: true, cancelable: true});
        box.dispatchEvent(move);
        box.dispatchEvent(new TouchEvent('touchend', {touches: [], changedTouches: t(150), bubbles: true, cancelable: true}));
        return move.defaultPrevented;
      })()
      """)

    assert prevented == false
  end

  test "14. a pinch clamps at 400% with + disabled, and − steps down to 300%", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)
    pinch(conn, 100, 1000)

    s = state(conn)
    assert s["label"] == "400%", inspect(s)
    assert s["inDisabled"]

    conn |> click("#mockup-viewer-zoom-out") |> assert_has("#mockup-viewer-zoom-reset", text: "300%")
  end

  test "15a. after a 173% pinch, + snaps up to the next step (200%)", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)
    pinch(conn, 100, 173)
    assert state(conn)["label"] == "173%"

    conn |> click("#mockup-viewer-zoom-in") |> assert_has("#mockup-viewer-zoom-reset", text: "200%")
  end

  test "15b. after a 173% pinch, − snaps down to the previous step (150%)", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)
    pinch(conn, 100, 173)
    assert state(conn)["label"] == "173%"

    conn |> click("#mockup-viewer-zoom-out") |> assert_has("#mockup-viewer-zoom-reset", text: "150%")
  end
end
