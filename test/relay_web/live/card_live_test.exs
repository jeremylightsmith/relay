defmodule RelayWeb.CardLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, card} = Cards.create_card(review, %{title: "Review me"})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})

    %{board: board, card: card, ref: Cards.ref(board, card)}
  end

  describe "/cards/:ref" do
    test "renders the card body with no board and no web chrome", %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#board-viewport")
      refute has_element?(view, "#top-bar")
    end

    test "the dead render is already chromeless — no header flash under the native bar", %{
      conn: conn,
      board: board,
      ref: ref
    } do
      html = conn |> get(~p"/cards/#{ref}?board=#{board.slug}") |> html_response(200)

      refute html =~ ~s(id="top-bar")
      refute html =~ ~s(id="board-viewport")
    end

    test "card mode is chromeless without ?embed=1 — the route implies it", %{
      conn: conn,
      board: board,
      ref: ref
    } do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")

      refute has_element?(view, "#top-bar")
    end

    test "keeps the review context but drops the web actions and dismissal", %{
      conn: conn,
      board: board,
      ref: ref
    } do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)

      # The context for the decision is the whole point of the screen.
      assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
      # The native bar is the only actor; the native back chevron owns dismissal.
      refute has_element?(view, "#review-approve")
      refute has_element?(view, "#review-request-changes")
      refute has_element?(view, "#card-drawer-scrim")
      refute has_element?(view, "#card-drawer-close")
    end

    test "approving stays on the card and updates in place (RLY-115)",
         %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)

      assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")

      # Card mode drops the web review buttons (the native bar is the actor, RLY-87), so
      # push the event straight to the view — the handler is shared with board mode.
      render_click(view, "review_approve", %{})

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#review-panel")
      assert has_element?(view, "#card-drawer .drawer-stage-chip", "Deploy")
      assert Cards.get_card_by_ref(board, ref).status == :working
    end

    test "an unknown ref is a 404", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/cards/ZZZ-9999") end
    end

    # Deliberately a *different* board key: every board defaults to "RLY", so an
    # other-user board with the default key would collide with this user's own RLY-1
    # and resolve to their card — the assertion would pass for the wrong reason.
    test "another user's card is a 404 — never leaking that it exists", %{conn: conn} do
      other_board = insert(:board, key: "ZZZ", slug: "other-board")
      insert(:membership, board: other_board, user: insert(:user))
      other_stage = insert(:stage, board: other_board, name: "Review", type: :review)
      insert(:card, stage: other_stage, ref_number: 1, title: "Not yours")

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/cards/ZZZ-1") end
    end
  end

  describe "/cards/:ref with duplicate board keys" do
    # Board keys are not unique. Derive the twin's key and ref_number from the card the
    # outer setup made, so the two boards genuinely produce the same ref string.
    setup %{user: user, board: board, card: card} do
      twin = insert(:board, key: board.key, slug: "twin-board")
      insert(:membership, board: twin, user: user)
      stage = insert(:stage, board: twin, name: "Review", type: :review)
      insert(:card, stage: stage, ref_number: card.ref_number, title: "The twin")

      %{twin: twin}
    end

    test "an ambiguous ref is a 404, not a guess at the wrong card", %{conn: conn, ref: ref} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/cards/#{ref}") end
    end

    test "?board= disambiguates", %{conn: conn, board: board, ref: ref, twin: twin} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)
      assert has_element?(view, "#card-drawer", "Review me")

      {:ok, twin_view, _html} = live(conn, ~p"/cards/#{ref}?board=#{twin.slug}")
      render_async(twin_view)
      assert has_element?(twin_view, "#card-drawer", "The twin")
    end
  end
end
