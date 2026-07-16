defmodule RelayWeb.BoardLiveSubTasksTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.SubTask

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, code: code}
  end

  test "no SUB-TASKS or AI RESULT section for a bare card", %{conn: conn, board: board, code: code} do
    {:ok, _card} = Cards.create_card(code, %{title: "Bare"})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#sub-tasks")
    refute has_element?(view, "#ai-result")
  end

  test "sub-tasks render with a count; toggling updates the count and persists",
       %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "With tasks"})
    {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "First"}, %{"title" => "Second"}])
    [first, _second] = card.sub_tasks

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)
    assert has_element?(view, "#sub-tasks-count", "0/2")
    assert has_element?(view, "#sub-task-#{first.id}", "First")

    view |> element("#sub-task-#{first.id} button") |> render_click()

    assert has_element?(view, "#sub-tasks-count", "1/2")
    assert Relay.Repo.get!(SubTask, first.id).done
  end

  test "AI RESULT renders its markdown summary and change rows when present",
       %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Resulted"})
    {:ok, _card} = Cards.update_ai_result(card, %{"summary" => "All **done**", "changes" => ["Wired it"]})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#ai-result")
    assert has_element?(view, "#ai-result-summary.md strong", "done")
    assert has_element?(view, "#ai-result-changes", "Wired it")
  end
end
