defmodule RelayWeb.BoardLivePublicSupportTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup %{conn: conn} do
    user = insert(:user)
    board = Boards.get_or_create_default_board(user)
    unstarted = Enum.find(board.stages, &(&1.category == :unstarted))
    card = insert(:card, stage: unstarted, board_id: board.id)
    %{conn: log_in_user(conn, user), board: board, card: card, user: user}
  end

  test "an unstarted card with votes shows the support badge on its face", %{conn: conn, board: board, card: card} do
    insert(:vote, card: card)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    assert has_element?(view, "article[data-ref='#{board.key}#{card.ref_number}'] .card-votes", "1")
  end

  test "the drawer shows Public support and the Add-a-public-description flow", %{
    conn: conn,
    board: board,
    card: card
  } do
    insert(:vote, card: card, user: insert(:user, name: "Maya L."))
    ref = Cards.ref(board, card)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    # RE282 — supporters make Public support a normal rail section; the empty description
    # waits behind the `1 unused field` row until it is expanded.
    assert has_element?(view, "#card-drawer-public-support", "Public support")
    refute has_element?(view, "#add-public-desc")
    assert has_element?(view, "#card-drawer-unused-toggle", "1 unused field")

    view |> element("#card-drawer-unused-toggle") |> render_click()
    view |> element("#add-public-desc") |> render_click()

    view
    |> form("#public-desc-form", %{"public_description" => "Ship the mobile app"})
    |> render_submit()

    assert render(view) =~ "Ship the mobile app"
    assert Cards.get_card_by_ref(board, "#{board.key}#{card.ref_number}").public_description == "Ship the mobile app"
  end
end
