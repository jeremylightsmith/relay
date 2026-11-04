defmodule HamacaWeb.Browser.TaskReorderTest do
  @moduledoc """
  RE507 — real-browser proof of the `TaskListDnD` hook: dragging a task's grip below the next
  row's midpoint pushes `move_task` with the drop slot computed EXCLUDING the dragged row, and
  the server's re-render (and the database) carry the new order. HTML5 drag-and-drop is
  client-side, so a LiveView test cannot see it.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias PlaywrightEx.Frame

  @moduletag :playwright

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Drag reorder"})

    {:ok, [a, b, c]} =
      Cards.add_tasks(card, [%{title: "Task A"}, %{title: "Task B"}, %{title: "Task C"}])

    %{board: board, card: card, a: a, b: b, c: c}
  end

  test "dragging A's grip below B's midpoint reorders to B, A, C", ctx do
    url = "/board/#{ctx.board.slug}?card=#{ctx.board.key}#{ctx.card.ref_number}"
    b_row = "#sub-task-#{ctx.b.id}"

    session =
      ctx.conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit(url)
      |> assert_has("#card-drawer-panel")
      |> assert_has("body .phx-connected")
      |> assert_has("#card-plan-tasks[data-editable='true']")

    height = row_height(session, b_row)

    session
    |> drag("#sub-task-#{ctx.a.id}-grip", to: b_row, playwright: [target_position: %{x: 10, y: height - 3}])
    |> assert_has("#card-plan-tasks li:nth-child(2)#sub-task-#{ctx.a.id}")
    |> assert_has("#card-plan-tasks li:nth-child(1)#sub-task-#{ctx.b.id}")
    |> assert_has("#card-plan-tasks li:nth-child(3)#sub-task-#{ctx.c.id}")

    assert ctx.card |> Cards.list_tasks() |> Enum.map(& &1.id) == [ctx.b.id, ctx.a.id, ctx.c.id]

    session
    |> visit(url)
    |> assert_has("#card-drawer-panel")
    |> assert_has("#card-plan-tasks li:nth-child(1)#sub-task-#{ctx.b.id}")
    |> assert_has("#card-plan-tasks li:nth-child(2)#sub-task-#{ctx.a.id}")
    |> assert_has("#card-plan-tasks li:nth-child(3)#sub-task-#{ctx.c.id}")
  end

  defp row_height(session, selector) do
    expression = "document.querySelector(#{Jason.encode!(selector)}).getBoundingClientRect().height"

    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(self(), {:evaluated, value})
    end)

    receive do
      {:evaluated, value} -> value
    end
  end
end
