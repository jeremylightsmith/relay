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

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
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

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)
    assert has_element?(view, "#sub-tasks-count", "0/2")
    assert has_element?(view, "#sub-task-#{first.id}", "First")

    view |> element("#sub-task-#{first.id} button") |> render_click()

    assert has_element?(view, "#sub-tasks-count", "1/2")
    assert Relay.Repo.get!(SubTask, first.id).done
  end

  test "AI RESULT renders its markdown summary and, behind Show more, its change rows",
       %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Resulted"})
    {:ok, _card} = Cards.update_ai_result(card, %{"summary" => "All **done**", "changes" => ["Wired it"]})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    assert has_element?(view, "#ai-result")
    assert has_element?(view, "#ai-result-summary.md strong", "done")
    refute has_element?(view, "#ai-result-changes")

    view |> element("#ai-result-show-more") |> render_click()

    assert has_element?(view, "#ai-result-changes", "Wired it")
  end

  test "AI RESULT Show more expands inside the box with labels, and Show less collapses it (RE316)",
       %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Resulted"})

    {:ok, _card} =
      Cards.update_ai_result(card, %{
        "summary" => "Did the thing",
        "changes" => ["changed A"],
        "screens" => [%{"url" => "https://placehold.co/320x180", "caption" => "home"}]
      })

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    assert has_element?(view, "#ai-result-summary", "Did the thing")
    # RE327 — the deployment link is gone from the box for good.
    refute has_element?(view, "#ai-result-deploy")
    assert has_element?(view, "#ai-result-show-more", "Show more")
    refute has_element?(view, "#ai-result-changes")
    refute has_element?(view, "#ai-result-screens")

    view |> element("#ai-result-show-more") |> render_click()

    assert has_element?(view, "#ai-result #ai-result-changes-group > span", "Changes")
    assert has_element?(view, "#ai-result #ai-result-changes", "changed A")
    assert has_element?(view, "#ai-result #ai-result-screens-group > span", "Screenshots")
    assert has_element?(view, "#ai-result #ai-result-screens figcaption", "home")
    assert has_element?(view, "#ai-result-show-more", "Show less")

    view |> element("#ai-result-show-more") |> render_click()

    refute has_element?(view, "#ai-result-changes")
    refute has_element?(view, "#ai-result-screens")
    assert has_element?(view, "#ai-result-summary", "Did the thing")
    assert has_element?(view, "#ai-result-show-more", "Show more")
  end

  test "AI RESULT expanded state does not leak to the next card (RE316)",
       %{conn: conn, board: board, code: code} do
    {:ok, first} = Cards.create_card(code, %{title: "First"})
    {:ok, _} = Cards.update_ai_result(first, %{"summary" => "first summary", "changes" => ["first change"]})
    {:ok, second} = Cards.create_card(code, %{title: "Second"})
    {:ok, _} = Cards.update_ai_result(second, %{"summary" => "second summary", "changes" => ["second change"]})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    view |> element("#ai-result-show-more") |> render_click()
    assert has_element?(view, "#ai-result-changes", "first change")

    # patch to the other card in the SAME mount → assign_selected_card resets the expanded state
    render_patch(view, ~p"/board/#{board.slug}?card=MY2")
    render_async(view)

    assert has_element?(view, "#ai-result-summary", "second summary")
    refute has_element?(view, "#ai-result-changes")
    assert has_element?(view, "#ai-result-show-more", "Show more")
  end
end
