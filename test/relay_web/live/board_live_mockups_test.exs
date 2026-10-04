defmodule RelayWeb.BoardLiveMockupsTest do
  @moduledoc """
  RE370 / RE374 — the drawer's Mockups section: a wrapping row of small square tiles, each a live
  miniature (sandboxed iframe) of an HTML attachment that is itself a same-tab patch link to the
  card's mockup viewer URL (RE380; never the raw HTML). Rendered only when the card has mockups, and live-updated on the
  `{:card_upserted, _}` echo.
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

  test "each mockup is a small square tile patching to the same-tab viewer URL, in a wrapping row (RE380)",
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

    # RE374 — tiles sit side by side and wrap, like the AI result's Screenshots strip.
    assert has_element?(view, "#card-drawer-mockups #card-drawer-mockup-tiles.flex.flex-wrap.gap-2")

    # RE380 — the whole 80px square tile is a same-tab patch to the card's own drawer URL plus
    # `mockup=<id>`: no new tab, and no current ring in the drawer.
    a_href = "/board/#{board.slug}?card=#{ref}&mockup=#{a.id}"

    assert has_element?(
             view,
             ~s|#card-drawer-mockup-tiles a#card-drawer-mockup-0-open.size-20[href="#{a_href}"][data-phx-link="patch"][title="Empty state"][aria-label="Open mockup: Empty state"]|
           )

    refute has_element?(view, "#card-drawer-mockup-0-open[target]")
    refute has_element?(view, "#card-drawer-mockup-0-open[rel]")
    refute has_element?(view, "#card-drawer-mockup-0-open[aria-current]")

    assert has_element?(
             view,
             ~s|#card-drawer-mockup-tiles a#card-drawer-mockup-1-open.size-20[href="/board/#{board.slug}?card=#{ref}&mockup=#{b.id}"][title="Mockup"][aria-label="Open mockup: Mockup"]|
           )

    refute has_element?(view, "#card-drawer-mockup-2-open")

    # The caption is no longer visible text, but it stays addressable and announced.
    assert has_element?(view, "#card-drawer-mockup-0-caption.sr-only", "Empty state")
    assert has_element?(view, "#card-drawer-mockup-1-caption.sr-only", "Mockup")

    # A live miniature: the same sandboxed iframe, inert (no pointer, no focus, hidden from AT).
    assert has_element?(
             view,
             ~s(#card-drawer-mockup-0-open iframe#card-drawer-mockup-0-frame.pointer-events-none[src="#{RelayWeb.attachment_path(a.id)}"][sandbox="#{RelayWeb.mockup_sandbox()}"][title="Empty state"][loading="lazy"][tabindex="-1"][aria-hidden="true"])
           )

    html = render(view)
    refute html =~ "allow-same-origin"
    refute html =~ "Open full size"

    refute has_element?(view, ~s(a[href="#{RelayWeb.attachment_path(a.id)}"]))
    refute has_element?(view, ~s(a[href="#{RelayWeb.attachment_path(b.id)}"]))
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
