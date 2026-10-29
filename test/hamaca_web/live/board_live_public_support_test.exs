defmodule HamacaWeb.BoardLivePublicSupportTest do
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Boards
  alias Hamaca.Cards

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

  test "a public card shows its outlined vote pill and a via-public-board requester in progress (RE500)", %{
    conn: conn,
    board: board,
    user: user
  } do
    in_progress = Enum.find(board.stages, &(&1.category == :in_progress))

    card =
      insert(:card,
        stage: in_progress,
        board_id: board.id,
        created_by_user_id: user.id,
        posted_by_user_id: user.id
      )

    insert(:vote, card: card, user: user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    article = "article[data-ref='#{Cards.ref(board, card)}']"
    assert view |> element("#{article} .card-public-votes") |> render() |> text_of() == "↑1"
    assert has_element?(view, "#{article} .card-requester[title*='via public board']")
  end

  test "an agent-created card shows the Hamaca AI requester (RE500)", %{conn: conn, board: board} do
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    card = insert(:card, stage: backlog, board_id: board.id, created_by_user_id: nil)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(
             view,
             "article[data-ref='#{Cards.ref(board, card)}'] .card-requester[data-requester='ai'][title='Requested by Hamaca AI']"
           )
  end

  test "an idea posted while the board is open turns up public, with its requester (RE500)", %{
    conn: conn,
    board: board,
    card: card
  } do
    # The setup card's factory ref_number can collide with the board's next ref.
    Hamaca.Repo.delete!(card)

    {:ok, board} =
      board
      |> Ecto.Changeset.change(public_enabled: true, public_intake_stage_id: hd(board.stages).id)
      |> Hamaca.Repo.update()

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    poster = insert(:user, name: "Maya L.")
    {:ok, card} = Cards.post_public_idea(board, poster, %{"title" => "Live idea"})
    render(view)

    article = "article[data-ref='#{Cards.ref(board, card)}']"
    assert view |> element("#{article} .card-public-votes") |> render() |> text_of() == "↑1"
    assert has_element?(view, "#{article} .card-requester[title='Requested by Maya L. · via public board']")
  end

  defp text_of(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.replace(~r/\s+/, "")

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
    # RE500 — the factory card has no requester, so Maya's one vote is the one other supporter.
    assert has_element?(view, "#card-drawer-public-support", "1 supporter")
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

  # RE500 — the drawer's Requested by row and Public support of the *other* supporters.
  defp public_requested_card(board) do
    requester = insert(:user, name: "Dana Kim", email: "dana@acme.co")

    card =
      insert(:card,
        stage: hd(board.stages),
        board_id: board.id,
        created_by_user_id: requester.id,
        posted_by_user_id: requester.id
      )

    {requester, card}
  end

  test "the drawer shows the requester and counts only the other supporters (RE500)", %{conn: conn, board: board} do
    {requester, card} = public_requested_card(board)
    for voter <- [requester, insert(:user), insert(:user)], do: insert(:vote, card: card, user: voter)

    ref = Cards.ref(board, card)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    assert view |> element("article[data-ref='#{ref}'] .card-public-votes") |> render() |> text_of() == "↑3"
    assert has_element?(view, "#card-drawer-public-support", "2 supporters")
    refute has_element?(view, "#card-drawer-public-support [data-avatar][title='Dana Kim']")

    requested_by = view |> element("#card-drawer-requested-by") |> render()
    assert requested_by =~ "Dana Kim"
    assert requested_by =~ "dana@acme.co"
    assert requested_by =~ "via public board"
  end

  test "a public card voted only by its requester folds Public support away (RE500)", %{conn: conn, board: board} do
    {requester, card} = public_requested_card(board)
    insert(:vote, card: card, user: requester)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)

    refute has_element?(view, "#card-drawer-public-support")
    assert has_element?(view, "#card-drawer-unused-toggle")
  end

  test "a new vote refreshes the face total and the other-supporters count (RE500)", %{conn: conn, board: board} do
    {requester, card} = public_requested_card(board)
    for voter <- [requester, insert(:user), insert(:user)], do: insert(:vote, card: card, user: voter)

    ref = Cards.ref(board, card)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    {:ok, :added} = Hamaca.Votes.toggle_vote(insert(:user), card)
    render(view)

    assert view |> element("article[data-ref='#{ref}'] .card-public-votes") |> render() |> text_of() == "↑4"
    assert has_element?(view, "#card-drawer-public-support", "3 supporters")
  end
end
