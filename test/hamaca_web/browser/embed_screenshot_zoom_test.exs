defmodule HamacaWeb.Browser.EmbedScreenshotZoomTest do
  @moduledoc """
  Real-browser (Playwright) test for RE405 / RE517 — the embedded (native app) viewer's
  screenshots: a PNG fits the frame width with CSS alone (never upscaled past its natural width,
  no JS zoom control) and never pages by swipe. Only a real browser lays the image out and runs
  the colocated `.MockupSwipe` hook.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias PlaywrightEx.Frame

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

  # Resolves once the image has loaded. A promise awaited by `evaluate`, not wait_for_function:
  # that re-polls through eval, which the page's CSP forbids, whenever the first check is false.
  defp await_image(conn) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, true} =
        Frame.evaluate(frame_id,
          expression: """
          (async () => {
            const i = document.querySelector('#mockup-viewer-image');
            if (!(i.complete && i.naturalWidth > 0)) await new Promise((r) => i.addEventListener('load', r, {once: true}));
            return i.naturalWidth > 0;
          })()
          """,
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

  # The frame box's scroll geometry and the image's rendered width.
  defp state(conn) do
    measure(conn, """
    (() => {
      const box = document.querySelector('[id^="mockup-viewer-frame-box-"]');
      const img = document.querySelector('#mockup-viewer-image');
      return {
        box: box.id,
        scrollWidth: box.scrollWidth,
        clientWidth: box.clientWidth,
        imgWidth: img.getBoundingClientRect().width,
        transform: getComputedStyle(img).transform,
        search: window.location.search
      };
    })()
    """)
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

  test "6. the screenshot CSS-fits the frame width: no sideways scroll, no transform, no zoom control",
       %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)
    s = state(conn)

    assert_in_delta s["imgWidth"], s["clientWidth"], 1
    assert s["scrollWidth"] == s["clientWidth"], inspect(s)
    assert s["transform"] == "none", inspect(s)
    refute_has(conn, "#mockup-viewer-zoom")
  end

  test "9. a leftward swipe never pages a screenshot", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)
    measure(conn, @swipe_left)
    # Give a (wrong) mockup_next push time to round-trip before checking it never happened.
    Process.sleep(500)

    conn = assert_has(conn, "#mockup-viewer-pager-count", text: "1 of 2")
    assert state(conn)["search"] =~ "screenshot=1"
  end

  test "11. the pager's next shows a narrow image at its natural width, never upscaled", %{conn: conn} = ctx do
    conn =
      conn
      |> visit_viewer(ctx)
      |> click("#mockup-viewer-pager-next")
      |> assert_has("#mockup-viewer-pager-count", text: "2 of 2")
      |> await_image()

    s = state(conn)
    assert s["search"] =~ "screenshot=2"
    assert s["imgWidth"] == 128, inspect(s)
  end
end
