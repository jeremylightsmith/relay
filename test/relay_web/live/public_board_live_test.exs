defmodule RelayWeb.PublicBoardLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Votes

  describe "a disabled or unknown public board" do
    test "404s when public_enabled is false", %{conn: conn} do
      board = insert(:board, public_enabled: false)
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/board/#{board.slug}/public") end
    end

    test "404s for an unknown slug", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/board/no-such-board/public") end
    end
  end

  describe "signed-out browsing" do
    setup do
      board = insert(:board, public_enabled: true)
      unstarted = insert(:stage, board: board, category: :unstarted)
      planning = insert(:stage, board: board, category: :planning)
      in_progress = insert(:stage, board: board, category: :in_progress)
      done = insert(:stage, board: board, category: :complete, type: :done)

      mobile = insert(:card, stage: unstarted, title: "Mobile app")
      _slack = insert(:card, stage: planning, title: "Slack alerts")
      _pdf = insert(:card, stage: in_progress, title: "PDF export")
      _shipped = insert(:card, stage: done, title: "Already shipped")

      %{board: board, unstarted: unstarted, mobile: mobile}
    end

    test "renders without requiring sign-in and does not redirect", %{conn: conn, board: board} do
      assert {:ok, _view, _html} = live(conn, ~p"/board/#{board.slug}/public")
    end

    test "shows three columns — Unstarted, Planning, In progress — each with a count",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      assert has_element?(view, "#public-column-unstarted", "Unstarted")
      assert has_element?(view, "#public-column-planning", "Planning")
      assert has_element?(view, "#public-column-in_progress", "In progress")

      assert has_element?(view, "#public-column-unstarted [data-column-count]", "1")
      assert has_element?(view, "#public-column-planning [data-column-count]", "1")
      assert has_element?(view, "#public-column-in_progress [data-column-count]", "1")
    end

    test "shows non-done cards but never the done/archived ones", %{conn: conn, board: board} do
      {:ok, view, html} = live(conn, ~p"/board/#{board.slug}/public")

      assert html =~ "Mobile app"
      assert html =~ "Slack alerts"
      assert html =~ "PDF export"
      refute html =~ "Already shipped"
      refute has_element?(view, "#public-column-complete")
    end

    test "the sort toggle re-sorts a column by votes vs. newest", %{conn: conn} do
      board = insert(:board, public_enabled: true)
      unstarted = insert(:stage, board: board, category: :unstarted)
      old_favorite = insert(:card, stage: unstarted, title: "Old favorite")
      _new_idea = insert(:card, stage: unstarted, title: "New idea")
      voter = insert(:user)
      Votes.toggle_vote(voter, old_favorite)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      # default sort is votes: the voted-for card leads
      column = view |> element("#public-column-unstarted") |> render()
      assert column =~ ~r/Old favorite.*New idea/s

      view |> element("#public-sort-new") |> render_click()

      column = view |> element("#public-column-unstarted") |> render()
      assert column =~ ~r/New idea.*Old favorite/s
    end

    test "an empty column shows the empty state", %{conn: conn} do
      board = insert(:board, public_enabled: true)
      insert(:stage, board: board, category: :unstarted)
      insert(:stage, board: board, category: :planning)
      insert(:stage, board: board, category: :in_progress)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      assert has_element?(view, "#public-column-unstarted", "Nothing here yet.")
    end

    test "clicking the vote pill while signed out opens the sign-in-to-vote modal",
         %{conn: conn, board: board, mobile: mobile} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      refute has_element?(view, "#public-signin-modal")

      view |> element("#public-vote-#{mobile.id}") |> render_click()

      assert has_element?(view, "#public-signin-modal", "Sign in to vote")
      assert has_element?(view, "#public-signin-google", "Continue with Google")
      refute has_element?(view, "#public-signin-modal", "Continue with email")
    end

    test "the header shows a Sign in link (not an avatar)", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      assert has_element?(view, "#public-board-sign-in", "Sign in")
    end

    test "the sign-in link carries return_to back to this public board", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      assert view
             |> element("#public-board-sign-in")
             |> render() =~ "/auth/google?return_to=%2Fboard%2F#{board.slug}%2Fpublic"
    end
  end

  describe "signed-in voting" do
    setup :register_and_log_in_user

    setup do
      board = insert(:board, public_enabled: true)
      unstarted = insert(:stage, board: board, category: :unstarted)
      card = insert(:card, stage: unstarted, title: "Mobile app")
      %{board: board, card: card}
    end

    test "toggles a vote on and off, flipping the pill and the count",
         %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      assert has_element?(view, "#public-vote-#{card.id}[data-voted=false]", "0")

      view |> element("#public-vote-#{card.id}") |> render_click()
      assert has_element?(view, "#public-vote-#{card.id}[data-voted=true]", "1")

      view |> element("#public-vote-#{card.id}") |> render_click()
      assert has_element?(view, "#public-vote-#{card.id}[data-voted=false]", "0")
    end

    test "never opens the sign-in modal for a signed-in visitor", %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      view |> element("#public-vote-#{card.id}") |> render_click()

      refute has_element?(view, "#public-signin-modal")
    end
  end

  describe "card detail modal — supporters gating" do
    setup do
      board = insert(:board, public_enabled: true)
      unstarted = insert(:stage, board: board, category: :unstarted)
      card = insert(:card, stage: unstarted, title: "Mobile app", public_description: "A native app.")
      supporter = insert(:user, name: "Maya Lin")
      Votes.toggle_vote(supporter, card)
      %{board: board, card: card, supporter: supporter}
    end

    test "signed-out sees a count-only gate, never a supporter name", %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      view |> element("#public-card-open-#{card.id}") |> render_click()

      assert has_element?(view, "#public-card-modal", "Sign in to see who")
      refute has_element?(view, "#public-card-modal", "Maya Lin")
      assert has_element?(view, "#public-card-modal", "A native app.")
    end

    test "signed-in sees the supporter's name", %{conn: conn, board: board, card: card} do
      viewer = insert(:user)

      {:ok, view, _html} = conn |> log_in_user(viewer) |> live(~p"/board/#{board.slug}/public")

      view |> element("#public-card-open-#{card.id}") |> render_click()

      assert has_element?(view, "#public-card-modal", "Maya Lin")
      refute has_element?(view, "#public-card-modal", "Sign in to see who")
    end
  end

  describe "real-time" do
    setup do
      board = insert(:board, public_enabled: true)
      unstarted = insert(:stage, board: board, category: :unstarted)
      card = insert(:card, stage: unstarted, title: "Mobile app")
      %{board: board, card: card}
    end

    test "a vote cast by another viewer updates this viewer's count live",
         %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

      assert has_element?(view, "#public-vote-#{card.id}", "0")

      voter = insert(:user)
      Votes.toggle_vote(voter, card)

      assert has_element?(view, "#public-vote-#{card.id}", "1")
    end
  end
end
