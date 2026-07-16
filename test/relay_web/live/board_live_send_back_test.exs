defmodule RelayWeb.BoardLiveSendBackTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  # Default pipeline: Backlog | Next up | Spec | Plan | Code | Review(:review type) | Deploy | Done.
  # Review is review-type by seed default, so it's already a gate — no setup needed.
  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Review"))
    %{board: board, spec: spec, code: code, review: review}
  end

  test "the amber banner renders for a card with an open rejection and names the target", %{
    conn: conn,
    review: review,
    user: user
  } do
    {:ok, card} = Cards.create_card(review, %{title: "Redo me"})
    {:ok, _sent} = Cards.reject(card, "Handle the empty case", :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#rejection-banner", "Changes requested")
    assert has_element?(view, "#rejection-banner", "Handle the empty case")
    assert has_element?(view, "#rejection-banner", "Code")
  end

  test "no banner for a clean card", %{conn: conn, code: code, user: user} do
    {:ok, _card} = Cards.create_card(code, %{title: "Clean"})
    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)
    refute has_element?(view, "#rejection-banner")
  end

  test "the standalone universal Send back control is gone from the drawer", %{conn: conn, board: board, code: code} do
    {:ok, _card} = Cards.create_card(code, %{title: "Bounce me"})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)
    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#send-back")
    refute has_element?(view, "#send-back-panel")
  end

  test "the gate reject panel is note-only and routes to the derived destination", %{
    conn: conn,
    board: board,
    code: code,
    review: review
  } do
    {:ok, card} = Cards.create_card(review, %{title: "Review me"})
    {:ok, _} = Cards.set_status(card, %{status: :in_review})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)
    view |> element("#review-request-changes") |> render_click()

    refute has_element?(view, "#review-reject-target")
    assert has_element?(view, "#review-send-back", "Reject → Code")

    view
    |> form("#review-reject-form", reject: %{note: "Tighten it"})
    |> render_submit()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.stage_id == code.id
    assert reloaded.rejection
  end
end
