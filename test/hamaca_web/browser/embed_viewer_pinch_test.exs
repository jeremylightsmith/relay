defmodule HamacaWeb.Browser.EmbedViewerPinchTest do
  @moduledoc """
  Real-browser (Playwright) test for RE517: the embedded mockup viewer enables the WebView's
  native pinch only while it is open. The colocated `.ViewerPinch` hook relaxes every
  `<meta name="viewport">` to the zoomable value on open, restores each to its own original
  (the root layout's is locked, RE400) on close, re-locks briefly on every item switch, and tells
  the native shell through the `relayViewerZoom` bridge — writing a meta or calling the bridge
  only on a real change. Only a real browser runs the hook.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Attachments
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias PlaywrightEx.Frame

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  @zoomable "width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=4, user-scalable=yes, viewport-fit=cover"
  @locked "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover"
  # What flutter_inappwebview_ios appends to <head> while the webview's supportZoom is false.
  @plugin_lock "width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no"

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, card} = Cards.create_card(review, %{title: "Pinch mockups"})

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
      |> Enum.map(fn {a, caption} -> %{"url" => HamacaWeb.attachment_path(a.id), "caption" => caption} end)

    {:ok, card} = Cards.set_mockups(card, entries)
    {:ok, card} = Cards.set_status(card, %{status: :in_review})

    %{board: board, card: card, ref: Cards.ref(board, card), m1: m1, m2: m2}
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

  defp card_url(ctx), do: "/cards/#{ctx.ref}?board=#{ctx.board.slug}&embed=1&back=Board"
  defp viewer_url(ctx, mockup), do: "#{card_url(ctx)}&mockup=#{mockup.id}"

  defp login(conn), do: conn |> visit("/dev/login") |> assert_has("body .phx-connected")

  # Resolves after two animation frames, so a hook's deferred (rAF) step has run.
  @settle "new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))"

  defp settle(conn), do: tap(conn, &measure(&1, @settle))

  defp viewport(conn), do: measure(conn, "document.querySelector('meta[name=viewport]').content")
  defp calls(conn), do: measure(conn, "window.__calls")

  defp viewports(conn),
    do: measure(conn, "Array.from(document.querySelectorAll('meta[name=viewport]')).map(m => m.content)")

  defp viewport_count(conn), do: measure(conn, "document.querySelectorAll('meta[name=viewport]').length")

  @append_plugin_meta """
  (() => {
    const meta = document.createElement('meta');
    meta.name = 'viewport';
    meta.content = '#{@plugin_lock}';
    document.head.appendChild(meta);
    return true;
  })()
  """

  @count_meta_writes """
  (() => {
    window.__metaWrites = 0;
    new MutationObserver((ms) => { window.__metaWrites += ms.length; })
      .observe(document.head, {attributes: true, subtree: true, attributeFilter: ['content']});
    return true;
  })()
  """

  @stub_bridge """
  (() => {
    window.__calls = [];
    window.flutter_inappwebview = {callHandler: (...a) => window.__calls.push(a)};
    return true;
  })()
  """

  @track_errors """
  (() => {
    window.__errors = [];
    window.addEventListener('error', (e) => window.__errors.push(String(e.message)));
    window.addEventListener('unhandledrejection', (e) => window.__errors.push(String(e.reason)));
    return true;
  })()
  """

  defp open_from_drawer(conn) do
    conn
    |> click("#card-drawer-mockup-0-open")
    |> assert_has("#mockup-viewer-pager-count", text: "1 of 2")
    |> settle()
  end

  defp close_viewer(conn) do
    conn
    |> click("#mockup-viewer-bar-back")
    |> refute_has("#mockup-viewer")
    |> settle()
  end

  defp open_stubbed(conn, ctx) do
    conn
    |> login()
    |> visit(card_url(ctx))
    |> await_connected()
    |> tap(&measure(&1, @stub_bridge))
    |> open_from_drawer()
  end

  defp open_with_plugin_meta(conn, ctx) do
    conn
    |> login()
    |> visit(card_url(ctx))
    |> await_connected()
    |> tap(&measure(&1, @stub_bridge))
    |> tap(&measure(&1, @append_plugin_meta))
    |> open_from_drawer()
  end

  test "RE517 pinch 7. opening the viewer relaxes the viewport and calls relayViewerZoom(true)",
       %{conn: conn} = ctx do
    conn = open_stubbed(conn, ctx)

    assert viewport(conn) == @zoomable
    assert calls(conn) == [["relayViewerZoom", true]]
  end

  test "RE517 pinch 8. closing the viewer restores the locked viewport and calls relayViewerZoom(false)",
       %{conn: conn} = ctx do
    conn = conn |> open_stubbed(ctx) |> close_viewer()

    assert viewport(conn) == @locked
    assert List.last(calls(conn)) == ["relayViewerZoom", false]
  end

  test "RE517 pinch 9. switching items re-locks, then relaxes again for the new item",
       %{conn: conn} = ctx do
    conn =
      conn
      |> open_stubbed(ctx)
      |> click("#mockup-viewer-pager-next")
      |> assert_has("#mockup-viewer-pager-count", text: "2 of 2")
      |> settle()

    assert Enum.take(calls(conn), -2) == [["relayViewerZoom", false], ["relayViewerZoom", true]]
    assert viewport(conn) == @zoomable
  end

  test "RE517 pinch 10. the original locked viewport is never overwritten by the relaxed one",
       %{conn: conn} = ctx do
    conn =
      conn
      |> login()
      |> visit(viewer_url(ctx, ctx.m1))
      |> await_connected()
      |> assert_has("#mockup-viewer-pager-count", text: "1 of 2")
      |> settle()

    assert viewport(conn) == @zoomable

    conn = conn |> close_viewer() |> open_from_drawer()
    assert viewport(conn) == @zoomable

    conn = close_viewer(conn)
    assert viewport(conn) == @locked
  end

  test "RE517 pinch 11. without the native bridge the viewer still toggles the viewport, error-free",
       %{conn: conn} = ctx do
    conn =
      conn
      |> login()
      |> visit(card_url(ctx))
      |> await_connected()
      |> tap(&measure(&1, @track_errors))
      |> open_from_drawer()

    assert measure(conn, "typeof window.flutter_inappwebview") == "undefined"
    assert viewport(conn) == @zoomable

    conn = close_viewer(conn)
    assert viewport(conn) == @locked
    assert measure(conn, "window.__errors") == []
  end

  test "RE517 pinch 12. opening the viewer relaxes every viewport meta, the plugin's too",
       %{conn: conn} = ctx do
    conn = open_with_plugin_meta(conn, ctx)

    assert viewports(conn) == [@zoomable, @zoomable]
  end

  test "RE517 pinch 13. closing the viewer restores each viewport meta to its own original",
       %{conn: conn} = ctx do
    conn = conn |> open_with_plugin_meta(ctx) |> close_viewer()

    assert viewports(conn) == [@locked, @plugin_lock]
  end

  test "RE517 pinch 14. paging and closing never adds or removes a viewport meta",
       %{conn: conn} = ctx do
    conn = open_with_plugin_meta(conn, ctx)
    assert viewport_count(conn) == 2

    conn =
      conn
      |> click("#mockup-viewer-pager-next")
      |> assert_has("#mockup-viewer-pager-count", text: "2 of 2")
      |> settle()

    assert viewport_count(conn) == 2

    conn =
      conn
      |> click("#mockup-viewer-pager-prev")
      |> assert_has("#mockup-viewer-pager-count", text: "1 of 2")
      |> settle()

    assert viewport_count(conn) == 2

    conn = close_viewer(conn)
    assert viewport_count(conn) == 2
    assert viewports(conn) == [@locked, @plugin_lock]
  end

  test "RE517 pinch 15. server patches while open neither rewrite the viewport nor re-call the bridge",
       %{conn: conn} = ctx do
    conn = open_stubbed(conn, ctx)
    assert calls(conn) == [["relayViewerZoom", true]]
    measure(conn, @count_meta_writes)

    conn =
      Enum.reduce(1..3, conn, fn i, conn ->
        {:ok, _card} = Cards.update_card(ctx.card, %{title: "Patched #{i}"})
        await_attached(conn, ~s{#mockup-viewer-card-title:has-text("Patched #{i}")})
        settle(conn)
      end)

    assert measure(conn, "window.__metaWrites") == 0
    assert calls(conn) == [["relayViewerZoom", true]]
    assert viewport(conn) == @zoomable
  end

  test "RE517 pinch 16. a LiveView reconnect while open neither re-calls nor flips the bridge",
       %{conn: conn} = ctx do
    conn = open_stubbed(conn, ctx)
    assert calls(conn) == [["relayViewerZoom", true]]

    measure(conn, "(() => { liveSocket.disconnect(); return true; })()")
    await_attached(conn, "[data-phx-main]:not(.phx-connected)")
    measure(conn, "(() => { liveSocket.connect(); return true; })()")
    conn = conn |> await_connected() |> settle()

    assert calls(conn) == [["relayViewerZoom", true]]
    assert viewport(conn) == @zoomable
  end
end
