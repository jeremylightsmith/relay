defmodule HamacaWeb.Browser.EmbedViewerPinchTest do
  @moduledoc """
  Real-browser (Playwright) test for RE517: the embedded mockup viewer enables the WebView's
  native pinch only while it is open. The colocated `.ViewerPinch` hook relaxes
  `<meta name="viewport">` to the zoomable value on open, restores the root layout's original
  (locked, RE400) value on close, re-locks briefly on every item switch, and tells the native
  shell through the `relayViewerZoom` bridge. Only a real browser runs the hook.
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
end
