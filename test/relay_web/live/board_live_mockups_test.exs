defmodule RelayWeb.BoardLiveMockupsTest do
  @moduledoc """
  RE370 — the drawer's Mockups section: caption, a sandboxed iframe of each HTML attachment, and
  an Open full size link to the framed viewer (never the raw HTML). Rendered only when the card
  has mockups, and live-updated on the `{:card_upserted, _}` echo.
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
    {:ok, card} = Cards.create_card(code, %{title: "Design it"})
    %{board: board, card: card, ref: Cards.ref(board, card)}
  end

  defp upload(card, name) do
    {:ok, attachment} =
      Attachments.create_attachment(card, %{
        filename: name,
        content_type: Schemas.Attachment.html_type(),
        bytes: "<p>#{name}</p>"
      })

    attachment
  end

  defp open(conn, board, ref) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)
    view
  end

  test "each mockup renders its caption, a sandboxed iframe and an Open full size link to the viewer",
       %{conn: conn, board: board, card: card, ref: ref} do
    a = upload(card, "a.html")
    b = upload(card, "b.html")

    {:ok, _card} =
      Cards.set_mockups(card, [
        %{"url" => RelayWeb.attachment_path(a.id), "caption" => "Empty state"},
        %{"url" => RelayWeb.attachment_path(b.id)}
      ])

    view = open(conn, board, ref)

    assert has_element?(view, "#card-drawer-mockups", "Mockups")
    assert has_element?(view, "#card-drawer-mockup-0-caption", "Empty state")
    assert has_element?(view, "#card-drawer-mockup-1-caption", "Mockup")

    assert has_element?(
             view,
             ~s(iframe#card-drawer-mockup-0-frame[src="#{RelayWeb.attachment_path(a.id)}"][sandbox="#{RelayWeb.mockup_sandbox()}"])
           )

    refute render(view) =~ "allow-same-origin"

    # RE370 review: Open full size opens the framed viewer in a NEW tab, leaving the board put.
    assert has_element?(
             view,
             ~s(#card-drawer-mockup-0-open[href="#{RelayWeb.attachment_view_path(a.id)}"][target="_blank"][rel="noopener noreferrer"]),
             "Open full size"
           )

    # A plain new-tab link, not a LiveView navigate (which would replace the board tab).
    refute has_element?(view, "#card-drawer-mockup-0-open[data-phx-link]")

    refute has_element?(view, ~s(a[href="#{RelayWeb.attachment_path(a.id)}"]))
  end

  test "no mockups, no section", %{conn: conn, board: board, ref: ref} do
    refute has_element?(open(conn, board, ref), "#card-drawer-mockups")
  end

  test "a replaced list repaints the open drawer without a reload", %{conn: conn, board: board, card: card, ref: ref} do
    first = upload(card, "first.html")
    {:ok, card} = Cards.set_mockups(card, [%{"url" => RelayWeb.attachment_path(first.id), "caption" => "First"}])
    view = open(conn, board, ref)
    assert has_element?(view, "#card-drawer-mockup-0-caption", "First")

    second = upload(card, "second.html")
    {:ok, _card} = Cards.set_mockups(card, [%{"url" => RelayWeb.attachment_path(second.id), "caption" => "Second"}])

    assert has_element?(view, "#card-drawer-mockup-0-caption", "Second")
    refute has_element?(view, "#card-drawer-mockups", "First")
  end
end
