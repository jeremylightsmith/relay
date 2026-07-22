defmodule RelayWeb.PublicBoardLiveYourIdeasTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Relay.Factory

  alias Relay.Cards
  alias Relay.Repo

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board, category: :unstarted, type: :queue, name: "Unstarted")

    {:ok, board} =
      board
      |> Ecto.Changeset.change(public_enabled: true, public_intake_stage_id: stage.id)
      |> Repo.update()

    %{board: board, stage: stage}
  end

  test "your own posted idea shows a YOUR IDEA badge; another user's does not", %{
    conn: conn,
    board: board
  } do
    me = insert(:user)
    them = insert(:user)
    {:ok, mine} = Cards.post_public_idea(board, me, %{"title" => "Mine"})
    {:ok, theirs} = Cards.post_public_idea(board, them, %{"title" => "Theirs"})

    conn = log_in_user(conn, me)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

    assert has_element?(view, "#public-card-#{mine.id} .your-idea-badge", "YOUR IDEA")
    refute has_element?(view, "#public-card-#{theirs.id} .your-idea-badge")
  end

  test "inline add-public-description appears only on your own description-less card and saves in place",
       %{conn: conn, board: board} do
    me = insert(:user)
    them = insert(:user)
    {:ok, mine} = Cards.post_public_idea(board, me, %{"title" => "Mine, no desc"})
    {:ok, theirs} = Cards.post_public_idea(board, them, %{"title" => "Theirs, no desc"})

    conn = log_in_user(conn, me)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

    # Mine offers the affordance; theirs does not.
    assert has_element?(view, "#add-desc-#{mine.id}", "Add a public description")
    refute has_element?(view, "#add-desc-#{theirs.id}")

    view |> element("#add-desc-#{mine.id}") |> render_click()
    assert has_element?(view, "#desc-editor-#{mine.id}")

    view
    |> form("#desc-form-#{mine.id}", desc: %{description: "Now with context."})
    |> render_submit()

    assert has_element?(view, "#public-card-#{mine.id}", "Now with context.")
    # Editor closed and the add-desc affordance is gone (card now has a description).
    refute has_element?(view, "#desc-editor-#{mine.id}")
    refute has_element?(view, "#add-desc-#{mine.id}")
    assert Repo.reload!(mine).public_description == "Now with context."
  end

  test "a non-poster cannot save a description on someone else's card", %{
    conn: conn,
    board: board
  } do
    me = insert(:user)
    author = insert(:user)
    {:ok, theirs} = Cards.post_public_idea(board, author, %{"title" => "Not mine"})

    conn = log_in_user(conn, me)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public")

    # Forge the event the UI never offers; the LiveView must reject it.
    render_hook(view, "save_desc", %{
      "card-id" => to_string(theirs.id),
      "desc" => %{"description" => "hacked"}
    })

    assert is_nil(Repo.reload!(theirs).public_description)
  end
end
