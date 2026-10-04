defmodule RelayWeb.MockupViewerLiveTest do
  @moduledoc """
  RE370 / RE380 — `/attachments/:id/view` is the legacy RE370 viewer link. It now redirects a
  member to BoardLive's same-tab mockup viewer (`/board/:slug?card=<ref>&mockup=<id>`), and is
  membership-scoped like the raw attachment: anything else is 404.
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

  test "redirects a member to the board's same-tab mockup viewer",
       %{conn: conn, board: board, html: html, ref: ref} do
    target = "/board/#{board.slug}?card=#{ref}&mockup=#{html.id}"

    assert {:error, {:live_redirect, %{to: ^target}}} =
             live(conn, RelayWeb.attachment_view_path(html.id))

    conn = get(conn, RelayWeb.attachment_view_path(html.id))
    assert redirected_to(conn, 302) == target
  end

  test "the redirect target opens BoardLive's viewer, with no RE370 banner",
       %{conn: conn, card: card, html: html} do
    {:ok, _card} =
      Cards.set_mockups(card, [%{"url" => RelayWeb.attachment_path(html.id), "caption" => "Empty state"}])

    {:error, {:live_redirect, %{to: target}}} = live(conn, RelayWeb.attachment_view_path(html.id))
    {:ok, view, _html} = live(conn, target)

    assert has_element?(view, "#mockup-viewer")
    refute has_element?(view, "#mockup-viewer-banner")
    refute render(view) =~ "mockup-viewer-banner"
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
