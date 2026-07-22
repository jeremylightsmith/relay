defmodule RelayWeb.PublicBoardLivePostTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Relay.Factory

  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Votes

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board, category: :unstarted, type: :queue, name: "Unstarted")

    {:ok, board} =
      board
      |> Ecto.Changeset.change(public_enabled: true, public_intake_stage_id: stage.id)
      |> Repo.update()

    %{board: board, stage: stage}
  end

  test "signed-out: opening the composer shows the 'Sign in to post' modal, no email button, no card",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

    assert has_element?(view, "#open-composer", "Post an idea")
    view |> element("#open-composer") |> render_click()

    assert has_element?(view, "#public-signin-modal", "Sign in to post")
    refute has_element?(view, "#public-signin-modal button", "Continue with email")
    refute has_element?(view, "#public-idea-composer")
  end

  test "signed-in: submitting the composer posts an idea that lands with ↑ 1 and a YOUR IDEA badge",
       %{conn: conn, board: board} do
    user = insert(:user)
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

    view |> element("#open-composer") |> render_click()
    assert has_element?(view, "#public-idea-composer")

    view
    |> form("#public-idea-composer", idea: %{title: "Dark mode"})
    |> render_submit()

    # Composer closes.
    refute has_element?(view, "#public-idea-composer")

    card = Repo.get_by!(Schemas.Card, title: "Dark mode", board_id: board.id)
    assert card.posted_by_user_id == user.id
    assert Votes.count(card.id) == 1

    # The card is on the board with its vote count and YOUR IDEA badge.
    assert has_element?(view, "#public-card-#{card.id}")
    assert has_element?(view, "#public-card-#{card.id}", "Dark mode")
    assert has_element?(view, "#public-card-#{card.id} .your-idea-badge", "YOUR IDEA")
    assert has_element?(view, "#public-card-#{card.id} [data-vote-count]", "1")
  end

  test "instant visibility: a second open public board shows a newly posted idea live",
       %{conn: conn, board: board} do
    # An already-open (signed-out) viewer.
    {:ok, viewer, _html} = live(conn, ~p"/board/#{board.slug}/public")

    # Another visitor posts out of band → create_card broadcasts {:card_upserted, card}.
    poster = insert(:user)
    {:ok, card} = Cards.post_public_idea(board, poster, %{"title" => "Live idea"})

    # render/1 processes the LiveView's pending {:card_upserted, ...} message.
    assert render(viewer) =~ "Live idea"
    assert has_element?(viewer, "#public-card-#{card.id}", "Live idea")
  end

  test "over the rate-limit cap: a friendly flash and no further card", %{conn: conn, board: board} do
    user = insert(:user)
    [{_window, hour_max} | _] = Cards.public_post_limits()
    for n <- 1..hour_max, do: {:ok, _} = Cards.post_public_idea(board, user, %{"title" => "Seed #{n}"})

    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")
    view |> element("#open-composer") |> render_click()

    html =
      view
      |> form("#public-idea-composer", idea: %{title: "One too many"})
      |> render_submit()

    assert html =~ "take a short break"
    # Composer stays open with the entered text; no new card.
    assert has_element?(view, "#public-idea-composer")
    refute Repo.get_by(Schemas.Card, title: "One too many", board_id: board.id)
  end

  test "no intake stage configured → the '＋ Post an idea' button is absent", %{conn: conn, board: board} do
    {:ok, board} = board |> Ecto.Changeset.change(public_intake_stage_id: nil) |> Repo.update()
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")
    refute has_element?(view, "#open-composer")
  end
end
