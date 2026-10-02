defmodule RelayWeb.MockupViewerLiveTest do
  @moduledoc """
  RE370 — `/attachments/:id/view` frames an HTML mockup under a banner naming its card, so Relay
  never presents a mockup as a bare top-level page. Membership-scoped like the raw attachment.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Design the empty state"})

    {:ok, html} =
      Attachments.create_attachment(card, %{
        filename: "empty.html",
        content_type: Schemas.Attachment.html_type(),
        bytes: "<!doctype html><p>Empty</p>"
      })

    {:ok, png} =
      Attachments.create_attachment(card, %{filename: "shot.png", content_type: "image/png", bytes: "png"})

    %{board: board, card: card, html: html, png: png, ref: Cards.ref(board, card)}
  end

  test "frames the mockup under a banner naming the card, linking back to it",
       %{conn: conn, board: board, card: card, html: html, ref: ref} do
    {:ok, view, _html} = live(conn, RelayWeb.attachment_view_path(html.id))

    assert has_element?(view, "#mockup-viewer-banner", "Mockup")
    assert has_element?(view, "#mockup-viewer-banner", ref)
    assert has_element?(view, "#mockup-viewer-banner", card.title)
    assert has_element?(view, ~s(#mockup-viewer-card-link[href="/board/#{board.slug}?card=#{ref}"]))

    assert has_element?(
             view,
             ~s(iframe#mockup-viewer-frame[src="#{RelayWeb.attachment_path(html.id)}"][sandbox="#{RelayWeb.mockup_sandbox()}"])
           )
  end

  test "a signed-in non-member gets 404", %{html: html} do
    other = log_in_user(build_conn(), insert(:user))
    assert_error_sent 404, fn -> get(other, RelayWeb.attachment_view_path(html.id)) end
  end

  test "an image attachment or an unknown id is 404 — only HTML is viewable", %{conn: conn, png: png} do
    assert_error_sent 404, fn -> get(conn, RelayWeb.attachment_view_path(png.id)) end
    assert_error_sent 404, fn -> get(conn, RelayWeb.attachment_view_path(Ecto.UUID.generate())) end
  end
end
