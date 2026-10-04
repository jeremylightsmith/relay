defmodule RelayWeb.Browser.MockupViewerMobileTest do
  @moduledoc """
  RE380 — real-browser check of the mockup viewer on a phone (390×844): one top bar (← back,
  caption over "n / m", ‹ ›) covering the app's top bar, no left sheet and no review controls —
  review stays in the mobile drawer. Taps, not swipes: touches over the sandboxed frame go to the
  frame's own document.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  @state """
  (() => {
    const visible = (sel) => { const el = document.querySelector(sel); return !!(el && el.offsetParent); };
    return {
      barVisible: visible('#mockup-viewer-bar'),
      sheetVisible: visible('#mockup-viewer-sheet'),
      approveVisible: visible('#review-approve'),
      requestVisible: visible('#review-request-changes'),
      viewerTop: document.querySelector('#mockup-viewer').getBoundingClientRect().top
    };
  })()
  """

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.type == :review))
    {:ok, card} = Cards.create_card(review, %{title: "Phone mockups"})

    mockups =
      for {caption, i} <- Enum.with_index(["Empty state", "Loaded", "Error"]) do
        {:ok, a} =
          Attachments.create_attachment(card, %{
            filename: "mockup-#{i}.html",
            content_type: Schemas.Attachment.html_type(),
            bytes: "<!doctype html><p>#{caption}</p>"
          })

        %{"url" => RelayWeb.attachment_path(a.id), "caption" => caption}
      end

    {:ok, card} = Cards.set_mockups(card, mockups)
    {:ok, card} = Cards.set_status(card, %{status: :in_review})

    %{board: board, ref: Cards.ref(board, card)}
  end

  # Scenario 10.
  test "one bar over the full-screen mockup: caption, n / m, ‹ › and ← back; no sheet, no review", ctx do
    session =
      ctx.conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit("/board/#{ctx.board.slug}?card=#{ctx.ref}")
      |> assert_has("#card-drawer-panel")
      |> assert_has("body .phx-connected")
      |> click("#card-drawer-mockup-1-open")
      |> assert_has("#mockup-viewer-bar")
      |> assert_has("#mockup-viewer-bar-count", text: "2 / 3")
      |> assert_has("#mockup-viewer-bar-caption", text: "Loaded")

    s = js_eval(session, @state)

    assert s["barVisible"], "the one-bar header is hidden on a phone"
    refute s["sheetVisible"], "the left sheet shows on a phone"
    refute s["approveVisible"], "Approve shows in the phone viewer"
    refute s["requestVisible"], "Request changes shows in the phone viewer"
    assert s["viewerTop"] == 0, "the viewer does not cover the app top bar: #{inspect(s)}"

    session =
      session
      |> click("#mockup-viewer-bar-next")
      |> assert_has("#mockup-viewer-bar-count", text: "3 / 3")
      |> assert_has("#mockup-viewer-bar-next[disabled]")
      |> click("#mockup-viewer-bar-back")
      |> refute_has("#mockup-viewer")

    assert js_eval(session, "(() => !!document.querySelector('#card-drawer-panel').offsetParent)()"),
           "the card drawer is not visible after ← back"

    refute js_eval(session, "(() => window.location.search)()") =~ "mockup"
  end

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
