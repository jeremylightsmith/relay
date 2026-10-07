defmodule RelayWeb.Browser.ScreenshotViewerTest do
  @moduledoc """
  RE390 — real-browser checks of AI Result screenshots in the same-tab viewer
  (`?card=<ref>&screenshot=<n>`): a PNG shows at its natural size in a frame that scrolls both
  ways, ←/→ stay within the screenshots and switch with replace patches (one history entry for
  the whole viewer visit), Esc returns to the drawer, and a markdown image still opens the RE322
  lightbox instead.

  Natural-size layout, scroll overflow and the history stack only exist in a real browser.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 800, height: 500}]

  @measure """
  (() => {
    const box = document.querySelector('#mockup-viewer-frame-box-1');
    const img = document.querySelector('#mockup-viewer-image');
    return {sw: box.scrollWidth, cw: box.clientWidth, sh: box.scrollHeight, ch: box.clientHeight,
            natural: img.naturalWidth, rendered: img.getBoundingClientRect().width};
  })()
  """

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))

    {:ok, card} =
      Cards.create_card(code, %{title: "Screenshot card", description: "![solo](/images/logo_dark_128.png)"})

    {:ok, mockup} =
      Attachments.create_attachment(card, %{
        filename: "mockup.html",
        content_type: Schemas.Attachment.html_type(),
        bytes: "<!doctype html><p>mockup</p>"
      })

    {:ok, card} =
      Cards.set_mockups(card, [%{"url" => RelayWeb.attachment_path(mockup.id), "caption" => "Mock"}])

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

  # Scenario 14.
  test "a screenshot tile opens the viewer with the PNG at actual size, scrolling both ways", ctx do
    session =
      ctx.conn
      |> open_screenshot(ctx.board, ctx.ref)
      |> refute_has("#image-lightbox[open]")

    assert search(session) =~ "screenshot=1"

    session = wait_until(session, "(() => document.querySelector('#mockup-viewer-image').complete)()")
    m = js_eval(session, @measure)

    assert m["sw"] > m["cw"], "the frame should scroll horizontally: #{inspect(m)}"
    assert m["sh"] > m["ch"], "the frame should scroll vertically: #{inspect(m)}"
    assert m["natural"] == 512
    assert m["rendered"] == 512, "the image is scaled, not at natural size: #{inspect(m)}"
  end

  # Scenario 15.
  test "← → stay within the screenshots with one history entry; Esc returns to the drawer", ctx do
    session = open_drawer(ctx.conn, ctx.board, ctx.ref)
    drawer_length = js_eval(session, "(() => history.length)()")

    session =
      session
      |> click("#ai-result-screen-0-open")
      |> assert_has("#mockup-viewer-header-noun", text: "Screenshot")
      |> assert_has("#mockup-viewer-header-count", text: "1 of 2")
      |> press_on("body", "ArrowRight")
      |> assert_has("#mockup-viewer-header-caption", text: "Small")
      |> assert_has("#mockup-viewer-header-count", text: "2 of 2")

    assert search(session) =~ "screenshot=2"

    session =
      session
      |> press_on("body", "ArrowRight")
      |> assert_has("#mockup-viewer-header-caption", text: "Small")
      |> assert_has("#mockup-viewer-header-count", text: "2 of 2")

    assert search(session) =~ "screenshot=2"
    refute search(session) =~ "mockup="
    assert js_eval(session, "(() => history.length)()") == drawer_length + 1

    session =
      session
      |> press_on("body", "Escape")
      |> refute_has("#mockup-viewer")

    assert visible?(session, "#card-drawer-panel")
    refute search(session) =~ "screenshot="
    refute search(session) =~ "mockup="
  end

  # Scenario 16.
  test "a markdown image keeps the lightbox and leaves the URL alone", ctx do
    session = open_drawer(ctx.conn, ctx.board, ctx.ref)
    before = search(session)

    session =
      session
      |> click("#card-drawer-description .md img[alt='solo']")
      |> assert_has("#image-lightbox[open]")

    assert search(session) == before
  end

  defp open_drawer(conn, board, ref) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{ref}")
    |> assert_has("#card-drawer-panel")
    # Keys pressed before THIS page's socket binds its window listeners are lost.
    |> assert_has("body .phx-connected")
    # RE401 — the screenshot tiles lead the AI Result box with no Show more click.
    |> assert_has("#ai-result-screen-0-open")
  end

  defp open_screenshot(conn, board, ref) do
    conn
    |> open_drawer(board, ref)
    |> click("#ai-result-screen-0-open")
    |> assert_has("#mockup-viewer-image")
  end

  defp wait_until(session, expression) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.wait_for_function(frame_id, expression: expression, timeout: 2_000)
    end)
  end

  defp press_on(session, selector, key) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.press(frame_id, selector: selector, key: key, timeout: 2_000)
    end)
  end

  defp visible?(session, selector) do
    js_eval(session, "(() => { const el = document.querySelector('#{selector}'); return !!(el && el.offsetParent) })()")
  end

  defp search(session), do: js_eval(session, "(() => window.location.search)()")

  defp js_eval(session, expression) do
    parent = self()

    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:evaluated, value})
    end)

    assert_received {:evaluated, value}
    value
  end
end
