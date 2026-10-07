defmodule RelayWeb.Browser.EmbedMockupViewerTest do
  @moduledoc """
  Real-browser (Playwright) test for RE393 · card mockup "Mockup viewer — one nav bar,
  phone/desktop toggle, pager above review bar": embedded at 390×844 the viewer shows one 44px
  nav bar (17px caption, 38px render-width segments), a 48px pager row, and a desktop mode that
  lays the mockup out at 1280px CSS-scaled to the frame width. Only a real browser computes the
  sizes and runs the `.MockupRenderWidth` hook (sessionStorage, re-apply after each patch).
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, card} = Cards.create_card(review, %{title: "Embedded mockups"})

    [m1, m2] =
      mockups =
      for i <- 0..1 do
        {:ok, a} =
          Attachments.create_attachment(card, %{
            filename: "mockup-#{i}.html",
            content_type: Schemas.Attachment.html_type(),
            bytes: "<!doctype html><p>mockup #{i}</p>"
          })

        a
      end

    entries =
      mockups
      |> Enum.zip(["Empty state", "Loaded"])
      |> Enum.map(fn {a, caption} -> %{"url" => RelayWeb.attachment_path(a.id), "caption" => caption} end)

    {:ok, card} = Cards.set_mockups(card, entries)
    {:ok, card} = Cards.set_status(card, %{status: :in_review})

    %{board: board, ref: Cards.ref(board, card), m1: m1, m2: m2}
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
      {:ok, _} = Frame.wait_for_selector(frame_id, selector: selector, state: "attached", timeout: 5_000)
    end)
  end

  defp await_connected(conn), do: await_attached(conn, "[data-phx-main].phx-connected")

  defp viewer_url(ctx, mockup), do: "/cards/#{ctx.ref}?board=#{ctx.board.slug}&embed=1&back=Board&mockup=#{mockup.id}"

  defp visit_viewer(conn, ctx) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit(viewer_url(ctx, ctx.m1))
    |> await_connected()
    |> assert_has("#mockup-viewer-pager-count", text: "1 of 2")
  end

  @frame_state """
  (() => {
    const box = document.querySelector('[id^="mockup-viewer-frame-box-"]');
    const frame = document.querySelector('#mockup-viewer-frame');
    return {
      box: box.id,
      render: box.dataset.render,
      boxWidth: box.getBoundingClientRect().width,
      viewportWidth: window.innerWidth,
      layoutWidth: document.documentElement.clientWidth,
      frameWidth: frame.getBoundingClientRect().width,
      offsetWidth: frame.offsetWidth,
      transform: getComputedStyle(frame).transform,
      stored: sessionStorage.getItem('relay:mockup-render'),
      desktopActive: document.querySelector('#mockup-viewer-width-desktop').dataset.active
    };
  })()
  """

  defp frame_state(conn), do: measure(conn, @frame_state)

  defp await_desktop(conn, box_id) do
    await_attached(conn, ~s([id="#{box_id}"][data-render="desktop"]))
  end

  # The scale factor of a `matrix(a, b, c, d, e, f)` transform.
  defp scale_of("matrix(" <> rest) do
    [a | _] = rest |> String.trim_trailing(")") |> String.split(",")
    a |> String.trim() |> Float.parse() |> elem(0)
  end

  test "7. the nav bar, toggle, pager and phone-width frame at iOS sizes", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)

    m =
      measure(conn, """
      (() => {
        const r = (sel) => document.querySelector(sel).getBoundingClientRect();
        const cs = (sel) => getComputedStyle(document.querySelector(sel));
        return {
          titleSize: cs('#mockup-viewer-bar-title').fontSize,
          phone: [r('#mockup-viewer-width-phone').width, r('#mockup-viewer-width-phone').height],
          desktop: [r('#mockup-viewer-width-desktop').width, r('#mockup-viewer-width-desktop').height],
          pagerH: r('#mockup-viewer-pager').height,
          prev: [r('#mockup-viewer-pager-prev').width, r('#mockup-viewer-pager-prev').height],
          prevDisabled: document.querySelector('#mockup-viewer-pager-prev').disabled,
          countText: document.querySelector('#mockup-viewer-pager-count').textContent.trim(),
          countSize: cs('#mockup-viewer-pager-count').fontSize
        };
      })()
      """)

    assert m["titleSize"] == "17px", inspect(m)
    assert m["phone"] == [38, 38], inspect(m)
    assert m["desktop"] == [38, 38], inspect(m)
    assert m["pagerH"] == 48, inspect(m)
    assert m["prev"] == [44, 44], inspect(m)
    assert m["prevDisabled"] == true, inspect(m)
    assert m["countText"] == "1 of 2", inspect(m)
    assert m["countSize"] == "13px", inspect(m)

    s = frame_state(conn)
    assert s["render"] == "phone", inspect(s)
    assert s["frameWidth"] == s["boxWidth"], inspect(s)
    # The frame fills the layout viewport. That is 390px wherever scrollbars overlay (iOS, macOS),
    # but the open card drawer's daisyUI scroll lock sets `scrollbar-gutter: stable` on <html>,
    # which reserves a classic 15px gutter on Linux Chromium (CI) — so measure the layout width
    # rather than hard-coding 390.
    assert s["viewportWidth"] == 390, inspect(s)
    assert_in_delta s["boxWidth"], s["layoutWidth"], 1
    assert s["layoutWidth"] >= 390 - 15, inspect(s)
  end

  # The open card drawer checks `.drawer-toggle`, which makes daisyUI set
  # `scrollbar-gutter: stable` on <html>. Where scrollbars are classic (Linux/Windows Chromium)
  # that reserves ~15px, shrinking every `fixed inset-0` overlay to 375px. macOS overlay
  # scrollbars reserve nothing, so only the computed style catches it on every platform.
  test "7b. embedded, the page reserves no root scrollbar gutter", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)

    assert measure(conn, "getComputedStyle(document.documentElement).scrollbarGutter") == "auto"
  end

  test "8. desktop lays the mockup out at 1280px scaled to the frame width", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> click("#mockup-viewer-width-desktop")
    box = "mockup-viewer-frame-box-#{ctx.m1.id}"
    await_desktop(conn, box)

    s = frame_state(conn)
    assert s["render"] == "desktop", inspect(s)
    assert s["offsetWidth"] == 1280, inspect(s)
    assert_in_delta scale_of(s["transform"]), s["boxWidth"] / 1280, 0.01
    assert s["stored"] == "desktop", inspect(s)
    assert s["desktopActive"] == "true", inspect(s)
  end

  test "9. desktop mode survives paging next and back", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> click("#mockup-viewer-width-desktop")
    await_desktop(conn, "mockup-viewer-frame-box-#{ctx.m1.id}")

    conn = conn |> click("#mockup-viewer-pager-next") |> assert_has("#mockup-viewer-pager-count", text: "2 of 2")
    await_desktop(conn, "mockup-viewer-frame-box-#{ctx.m2.id}")
    s = frame_state(conn)
    assert s["render"] == "desktop", inspect(s)
    assert s["offsetWidth"] == 1280, inspect(s)

    conn = conn |> click("#mockup-viewer-pager-prev") |> assert_has("#mockup-viewer-pager-count", text: "1 of 2")
    await_desktop(conn, "mockup-viewer-frame-box-#{ctx.m1.id}")
    s = frame_state(conn)
    assert s["render"] == "desktop", inspect(s)
    assert s["offsetWidth"] == 1280, inspect(s)
  end

  test "10. desktop mode survives leaving the viewer and reopening it", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> click("#mockup-viewer-width-desktop")
    await_desktop(conn, "mockup-viewer-frame-box-#{ctx.m1.id}")

    conn =
      conn
      |> click("#mockup-viewer-bar-back")
      |> refute_has("#mockup-viewer")
      |> click("#card-drawer-mockup-0-open")
      |> assert_has("#mockup-viewer-pager-count", text: "1 of 2")

    await_desktop(conn, "mockup-viewer-frame-box-#{ctx.m1.id}")
    assert frame_state(conn)["render"] == "desktop"
  end

  test "11. dark theme: the pager takes the dark base-100", %{conn: conn} = ctx do
    conn =
      conn
      |> visit_viewer(ctx)
      |> tap(&measure(&1, "localStorage.setItem('phx:theme', 'dark')"))
      |> visit(viewer_url(ctx, ctx.m1))
      |> await_attached("html[data-theme=dark]")
      |> assert_has("#mockup-viewer-pager-count", text: "1 of 2")

    m =
      measure(conn, """
      (() => {
        const probe = document.createElement('div');
        probe.style.backgroundColor = 'var(--color-base-100)';
        document.querySelector('main').appendChild(probe);
        const base100 = getComputedStyle(probe).backgroundColor;
        probe.remove();
        return {base100, pager: getComputedStyle(document.querySelector('#mockup-viewer-pager')).backgroundColor};
      })()
      """)

    assert m["pager"] == m["base100"], inspect(m)
    refute m["pager"] == "rgb(255, 255, 255)", inspect(m)
  end

  # RE393 delta — "mockups need to be scalable and horizontally scrollable". The zoom control's
  # state, the frame box's scroll geometry (after trying to scroll it to `scroll_left`), the
  # sizer and the iframe's layout size and transform.
  defp zoom_state(conn, scroll_left \\ 0) do
    measure(conn, """
    (() => {
      const box = document.querySelector('[id^="mockup-viewer-frame-box-"]');
      const sizer = document.querySelector('#mockup-viewer-frame-sizer');
      const frame = document.querySelector('#mockup-viewer-frame');
      box.scrollLeft = #{scroll_left};
      return {
        box: box.id,
        render: box.dataset.render,
        zoom: box.dataset.zoom,
        scrollWidth: box.scrollWidth,
        clientWidth: box.clientWidth,
        clientHeight: box.clientHeight,
        scrollLeft: box.scrollLeft,
        boxWidth: box.getBoundingClientRect().width,
        sizerWidth: sizer.getBoundingClientRect().width,
        offsetWidth: frame.offsetWidth,
        offsetHeight: frame.offsetHeight,
        transform: getComputedStyle(frame).transform,
        label: document.querySelector('#mockup-viewer-zoom-reset').textContent.trim(),
        outDisabled: document.querySelector('#mockup-viewer-zoom-out').disabled,
        inDisabled: document.querySelector('#mockup-viewer-zoom-in').disabled
      };
    })()
    """)
  end

  defp zoom_to(conn, label, clicks) do
    conn = Enum.reduce(1..clicks//1, conn, fn _, c -> click(c, "#mockup-viewer-zoom-in") end)
    assert_has(conn, "#mockup-viewer-zoom-reset", text: label)
  end

  test "Z1. at Fit the zoom control shows Fit, − disabled, 44px targets, no sideways scroll", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)
    conn = assert_has(conn, "#mockup-viewer-zoom")

    m =
      measure(conn, """
      (() => {
        const r = (sel) => document.querySelector(sel).getBoundingClientRect();
        return {
          out: [r('#mockup-viewer-zoom-out').width, r('#mockup-viewer-zoom-out').height],
          in: [r('#mockup-viewer-zoom-in').width, r('#mockup-viewer-zoom-in').height],
          reset: [r('#mockup-viewer-zoom-reset').width, r('#mockup-viewer-zoom-reset').height]
        };
      })()
      """)

    assert m["out"] == [44, 44], inspect(m)
    assert m["in"] == [44, 44], inspect(m)
    [rw, rh] = m["reset"]
    assert rw >= 44 and rh >= 44, inspect(m)

    z = zoom_state(conn)
    assert z["label"] == "Fit", inspect(z)
    assert z["outDisabled"] == true, inspect(z)
    assert z["zoom"] == "1", inspect(z)
    assert z["scrollWidth"] == z["clientWidth"], inspect(z)
  end

  test "Z2. phone: one + zooms to 150% and the frame box scrolls sideways", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> zoom_to("150%", 1)

    z = zoom_state(conn, 100)
    assert z["zoom"] == "1.5", inspect(z)
    assert_in_delta scale_of(z["transform"]), 1.5, 0.01
    assert_in_delta z["offsetWidth"], z["clientWidth"], 1
    assert_in_delta z["scrollWidth"], 1.5 * z["clientWidth"], 2
    assert z["scrollLeft"] == 100, inspect(z)
    assert_in_delta z["offsetHeight"], z["clientHeight"] / 1.5, 2
    assert z["outDisabled"] == false, inspect(z)
  end

  test "Z3. desktop: two + zoom the 1280px render to 200% and it scrolls sideways", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> click("#mockup-viewer-width-desktop")
    await_desktop(conn, "mockup-viewer-frame-box-#{ctx.m1.id}")
    conn = zoom_to(conn, "200%", 2)

    z = zoom_state(conn, 200)
    assert_in_delta scale_of(z["transform"]), 2 * z["boxWidth"] / 1280, 0.01
    assert z["offsetWidth"] == 1280, inspect(z)
    assert_in_delta z["scrollWidth"], 2 * z["clientWidth"], 2
    assert z["scrollLeft"] == 200, inspect(z)
  end

  test "Z4. phone: four + reach 400%, + disables, a fifth click stays at 400%", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> zoom_to("400%", 4)

    z = zoom_state(conn)
    assert z["inDisabled"] == true, inspect(z)

    measure(conn, "document.querySelector('#mockup-viewer-zoom-in').click()")
    z = zoom_state(conn)
    assert z["label"] == "400%", inspect(z)
    assert z["zoom"] == "4", inspect(z)
  end

  test "Z5. Fit resets a 200% phone zoom: no sideways scroll, transform none", %{conn: conn} = ctx do
    conn =
      conn
      |> visit_viewer(ctx)
      |> zoom_to("200%", 2)
      |> click("#mockup-viewer-zoom-reset")
      |> assert_has("#mockup-viewer-zoom-reset", text: "Fit")

    z = zoom_state(conn)
    assert z["zoom"] == "1", inspect(z)
    assert z["scrollWidth"] == z["clientWidth"], inspect(z)
    assert z["transform"] == "none", inspect(z)
  end

  test "Z6. paging resets zoom to Fit while desktop render width persists", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> click("#mockup-viewer-width-desktop")
    await_desktop(conn, "mockup-viewer-frame-box-#{ctx.m1.id}")

    conn =
      conn
      |> zoom_to("150%", 1)
      |> click("#mockup-viewer-pager-next")
      |> assert_has("#mockup-viewer-pager-count", text: "2 of 2")

    await_desktop(conn, "mockup-viewer-frame-box-#{ctx.m2.id}")
    conn = assert_has(conn, "#mockup-viewer-zoom-reset", text: "Fit")

    z = zoom_state(conn)
    assert z["box"] == "mockup-viewer-frame-box-#{ctx.m2.id}", inspect(z)
    assert z["zoom"] == "1", inspect(z)
    assert z["label"] == "Fit", inspect(z)
    assert z["render"] == "desktop", inspect(z)
  end

  test "Z7. switching width resets zoom to Fit", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> zoom_to("150%", 1) |> click("#mockup-viewer-width-desktop")
    await_desktop(conn, "mockup-viewer-frame-box-#{ctx.m1.id}")
    conn = assert_has(conn, "#mockup-viewer-zoom-reset", text: "Fit")

    z = zoom_state(conn)
    assert z["label"] == "Fit", inspect(z)
    assert_in_delta scale_of(z["transform"]), z["boxWidth"] / 1280, 0.01
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

  test "Z8a. at Fit a leftward swipe pages to the next mockup", %{conn: conn} = ctx do
    conn = visit_viewer(conn, ctx)
    measure(conn, @swipe_left)
    assert_has(conn, "#mockup-viewer-pager-count", text: "2 of 2")
  end

  test "Z8b. zoomed past Fit the same swipe stays on the mockup", %{conn: conn} = ctx do
    conn = conn |> visit_viewer(ctx) |> zoom_to("150%", 1)
    measure(conn, @swipe_left)
    # Give a (wrong) mockup_next push time to round-trip before checking it never happened.
    Process.sleep(500)
    assert_has(conn, "#mockup-viewer-pager-count", text: "1 of 2")
    assert zoom_state(conn)["box"] == "mockup-viewer-frame-box-#{ctx.m1.id}"
  end

  test "Z10. dark theme: the zoom control takes the dark base-100", %{conn: conn} = ctx do
    conn =
      conn
      |> visit_viewer(ctx)
      |> tap(&measure(&1, "localStorage.setItem('phx:theme', 'dark')"))
      |> visit(viewer_url(ctx, ctx.m1))
      |> await_attached("html[data-theme=dark]")
      |> assert_has("#mockup-viewer-zoom")

    m =
      measure(conn, """
      (() => {
        const probe = document.createElement('div');
        probe.style.backgroundColor = 'var(--color-base-100)';
        document.querySelector('main').appendChild(probe);
        const base100 = getComputedStyle(probe).backgroundColor;
        probe.remove();
        return {base100, zoom: getComputedStyle(document.querySelector('#mockup-viewer-zoom')).backgroundColor};
      })()
      """)

    assert m["zoom"] == m["base100"], inspect(m)
    refute m["zoom"] == "rgb(255, 255, 255)", inspect(m)
  end
end
