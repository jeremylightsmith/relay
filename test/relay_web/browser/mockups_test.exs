defmodule RelayWeb.Browser.MockupsTest do
  @moduledoc """
  RE370 — real-browser check that the drawer frames a card's HTML mockup in a sandboxed iframe
  and that Open full size opens the framed viewer with its banner in a new tab (not the raw HTML,
  not in place of the board).
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Relay.Accounts
  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

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

    {:ok, card} = Cards.set_mockups(card, [%{"url" => RelayWeb.attachment_path(html.id), "caption" => "Empty state"}])

    %{board: board, card: card, html: html, ref: Cards.ref(board, card)}
  end

  test "the drawer frames the mockup and Open full size opens the banner viewer in a new tab", ctx do
    view_path = RelayWeb.attachment_view_path(ctx.html.id)

    ctx.conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{ctx.board.slug}?card=#{ctx.ref}")
    |> assert_has("#card-drawer-panel")
    |> assert_has("#card-drawer-mockups", text: "Empty state")
    |> assert_has(~s(iframe#card-drawer-mockup-0-frame[sandbox="#{RelayWeb.mockup_sandbox()}"]))
    |> assert_has(
      ~s(a#card-drawer-mockup-0-open[href="#{view_path}"][target="_blank"][rel="noopener noreferrer"]),
      text: "Open full size"
    )
    |> visit(view_path)
    |> assert_has("#mockup-viewer-banner", text: ctx.ref)
    |> assert_has("#mockup-viewer-banner", text: ctx.card.title)
    |> assert_has(~s(iframe#mockup-viewer-frame[src="#{RelayWeb.attachment_path(ctx.html.id)}"]))
  end
end
