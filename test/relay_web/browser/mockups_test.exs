defmodule RelayWeb.Browser.MockupsTest do
  @moduledoc """
  RE370 / RE374 — real-browser check that the drawer shows a card's HTML mockups as small square
  tiles (a sandboxed live miniature each) side by side in one row, and that a tile opens the framed
  viewer with its banner in a new tab (not the raw HTML, not in place of the board).
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  # Bounding boxes of both tiles and the first tile's (CSS-scaled) iframe.
  @measure """
  (() => {
    const box = (sel) => { const r = document.querySelector(sel).getBoundingClientRect();
      return {top: r.top, left: r.left, w: r.width, h: r.height}; };
    return {t0: box('#card-drawer-mockup-0-open'), t1: box('#card-drawer-mockup-1-open'),
            f0: box('#card-drawer-mockup-0-frame')};
  })()
  """

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Mockup card"})

    {:ok, html} =
      Attachments.create_attachment(card, %{
        filename: "empty.html",
        content_type: Schemas.Attachment.html_type(),
        bytes: ~s{<!doctype html><p id="t">before</p><script>document.getElementById("t").textContent = "after"</script>}
      })

    {:ok, loaded} =
      Attachments.create_attachment(card, %{
        filename: "loaded.html",
        content_type: Schemas.Attachment.html_type(),
        bytes: ~s{<!doctype html><p>loaded</p>}
      })

    {:ok, card} =
      Cards.set_mockups(card, [
        %{"url" => RelayWeb.attachment_path(html.id), "caption" => "Empty state"},
        %{"url" => RelayWeb.attachment_path(loaded.id), "caption" => "Loaded"}
      ])

    %{board: board, card: card, html: html, ref: Cards.ref(board, card)}
  end

  test "the drawer shows mockups as small square tiles in one row; a tile opens the banner viewer in a new tab",
       ctx do
    view_path = RelayWeb.attachment_view_path(ctx.html.id)

    session =
      ctx.conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit("/board/#{ctx.board.slug}?card=#{ctx.ref}")
      |> assert_has("#card-drawer-panel")
      |> assert_has("#card-drawer-mockups", text: "Mockups")
      |> assert_has(~s(iframe#card-drawer-mockup-0-frame[sandbox="#{RelayWeb.mockup_sandbox()}"]))
      |> assert_has(
        ~s(a#card-drawer-mockup-0-open[href="#{view_path}"][target="_blank"][rel="noopener noreferrer"][title="Empty state"])
      )
      |> assert_has(~s(a#card-drawer-mockup-1-open[title="Loaded"]))

    m = measure(session)

    for tile <- [m["t0"], m["t1"]] do
      assert tile["w"] <= 81 and tile["h"] <= 81, "tile is not ~80px: #{inspect(tile)}"
      assert abs(tile["w"] - tile["h"]) < 1, "tile is not square: #{inspect(tile)}"
    end

    assert abs(m["t0"]["top"] - m["t1"]["top"]) < 1,
           "two mockups should share one row: #{inspect({m["t0"], m["t1"]})}"

    assert m["t1"]["left"] > m["t0"]["left"]

    # The 1280px iframe is scaled down to fit its tile.
    assert m["f0"]["w"] <= m["t0"]["w"] + 1, "the miniature overflows its tile: #{inspect(m["f0"])}"

    session
    |> visit(view_path)
    |> assert_has("#mockup-viewer-banner", text: ctx.ref)
    |> assert_has("#mockup-viewer-banner", text: ctx.card.title)
    |> assert_has(~s(iframe#mockup-viewer-frame[src="#{RelayWeb.attachment_path(ctx.html.id)}"]))
  end

  defp measure(session) do
    parent = self()

    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, m} = Frame.evaluate(frame_id, expression: @measure, timeout: 2_000)
      send(parent, {:measure, m})
    end)

    assert_received {:measure, m}
    m
  end
end
