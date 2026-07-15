defmodule RelayWeb.BoardLiveAcceptanceCriteriaTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    [backlog | _rest] = board.stages
    {:ok, card} = Cards.create_card(backlog, %{title: "Criteria card"})

    {:ok, _} = Cards.update_card(card, %{acceptance_criteria: "### 1. Old\n1. Expect: **oldbold**"})

    %{board: board, card: card}
  end

  test "the drawer renders the acceptance criteria as markdown, collapsed", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#card-drawer-acceptance-criteria-view strong", "oldbold")
    assert has_element?(view, "#card-drawer-acceptance-criteria-show-more")
  end

  test "Show more expands the section", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    view |> element("#card-drawer-acceptance-criteria-show-more") |> render_click()

    refute has_element?(view, "#card-drawer-acceptance-criteria-show-more")
  end

  test "editing and saving the criteria re-renders them as markdown", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    render_click(view, "edit_acceptance_criteria", %{})
    assert has_element?(view, "#card-drawer-acceptance-criteria-input")

    view
    |> element("#card-drawer-acceptance-criteria-form")
    |> render_submit(%{"card" => %{"acceptance_criteria" => "### 1. New\n1. Expect: **newbold**"}})

    assert has_element?(view, "#card-drawer-acceptance-criteria-view strong", "newbold")
    assert Cards.get_card_by_ref(board, "RLY-1").acceptance_criteria =~ "newbold"
  end
end
