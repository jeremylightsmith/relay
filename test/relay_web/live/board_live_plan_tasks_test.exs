defmodule RelayWeb.BoardLivePlanTasksTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo
  alias Schemas.Flow.Node
  alias Schemas.SubTask

  setup :register_and_log_in_user

  # Built rather than typed so no literal triple-backtick appears in this source.
  @fence String.duplicate("`", 3)

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Accordion"})

    {:ok, tasks} =
      Cards.add_tasks(card, [
        %{title: "Long task", body: long_body()},
        %{title: "Short task", body: "Just one line."},
        %{title: "Third task", body: "Third body."},
        %{title: "No body", body: nil}
      ])

    %{board: board, card: card, tasks: tasks}
  end

  # 24 prose lines + blank + 3-line block + blank + 3-line block = 32 lines, 2 code blocks.
  defp long_body do
    prose = Enum.map_join(1..24, "\n", &"Line #{&1} of the long task.")
    prose <> "\n\n#{@fence}elixir\nx = 1\n#{@fence}\n\n#{@fence}elixir\ny = 2\n#{@fence}\n"
  end

  defp open(conn, board, card) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)
    view
  end

  # An active foreach run whose `impl` node is bound to `task` — no engine, just the rows
  # `Relay.Runs.in_flight_sub_task_id/1` reads.
  defp active_run(board, card, task) do
    flow =
      insert(:flow,
        board: board,
        nodes: [
          %Node{key: "impl", type: :agent, run: "impl {ref}", foreach: "card.tasks"},
          %Node{key: "review", type: :agent, run: "review {ref}"}
        ]
      )

    run = insert(:run, card: card, flow_id: flow.id, flow_key: flow.key, status: :running, current_node: "impl")
    bind(run, task)
    run
  end

  defp bind(run, task) do
    insert(:node_execution, run: run, node_key: "impl", sub_task_id: task.id, outcome: nil, duration_s: nil)
  end

  # The run-event path: mark the card dirty, then flush immediately instead of waiting out the
  # 150ms debounce (the timer's own later flush finds an empty dirty set and is a no-op).
  defp run_refresh(view, card) do
    send(view.pid, {:run_changed, card.id})
    send(view.pid, :flush_run_changes)
  end

  test "collapsed rows show the meta; a body-less task has no meta and no chevron", ctx do
    [long, short, _third, none] = ctx.tasks
    view = open(ctx.conn, ctx.board, ctx.card)

    assert has_element?(view, "#sub-task-#{long.id}-meta", "32 lines · 2 code blocks")
    assert has_element?(view, "#sub-task-#{short.id}-meta", "1 line")
    assert has_element?(view, "#sub-task-#{long.id}-toggle .hero-chevron-down")
    refute has_element?(view, "#sub-task-#{none.id}-meta")
    refute has_element?(view, "#sub-task-#{none.id} .hero-chevron-down")
    refute has_element?(view, "button#sub-task-#{none.id}-toggle")
    refute has_element?(view, "#card-plan-tasks [id$='-body']")
  end

  test "plan and tasks are one PLAN section with no separate Sub-tasks section", ctx do
    {:ok, _} = Cards.update_card(ctx.card, %{plan: "Short header for the plan."})
    [long | _] = ctx.tasks
    view = open(ctx.conn, ctx.board, ctx.card)

    assert has_element?(view, "#card-plan #card-plan-count", "0/4")
    assert has_element?(view, "#card-plan #card-plan-view", "Short header for the plan.")
    assert has_element?(view, "#card-plan #card-plan-tasks #sub-task-#{long.id}")
    refute has_element?(view, "#sub-tasks")
    refute render(view) =~ "Sub-tasks"
  end

  test "the disclosure opens the body; the checkbox toggles done without opening", ctx do
    [_long, short, _third, _none] = ctx.tasks
    view = open(ctx.conn, ctx.board, ctx.card)

    view |> element("#sub-task-#{short.id}-check") |> render_click()

    assert Repo.get!(SubTask, short.id).done
    assert has_element?(view, "#card-plan-count", "1/4")
    refute has_element?(view, "#sub-task-#{short.id}-body")

    view |> element("#sub-task-#{short.id}-toggle") |> render_click()

    assert has_element?(view, "#sub-task-#{short.id}-body.md", "Just one line.")
    assert has_element?(view, "#sub-task-#{short.id}-head.sticky")
    # still done: opening never touched the checkbox
    assert Repo.get!(SubTask, short.id).done
  end

  test "only one task is open at a time; re-clicking the open one collapses it", ctx do
    [long, short, _third, _none] = ctx.tasks
    view = open(ctx.conn, ctx.board, ctx.card)

    view |> element("#sub-task-#{long.id}-toggle") |> render_click()
    assert has_element?(view, "#sub-task-#{long.id}-body")

    view |> element("#sub-task-#{short.id}-toggle") |> render_click()
    assert has_element?(view, "#sub-task-#{short.id}-body")
    refute has_element?(view, "#sub-task-#{long.id}-body")

    view |> element("#sub-task-#{short.id}-toggle") |> render_click()
    refute has_element?(view, "#card-plan-tasks [id$='-body']")
  end

  test "a >16-line body clamps behind Show all N lines; toggling swaps to Collapse", ctx do
    [long, short, _third, _none] = ctx.tasks
    view = open(ctx.conn, ctx.board, ctx.card)

    view |> element("#sub-task-#{long.id}-toggle") |> render_click()
    assert has_element?(view, "#sub-task-#{long.id}-body.task-body-clamped")
    assert has_element?(view, "#sub-task-#{long.id}-full", "Show all 32 lines")

    view |> element("#sub-task-#{long.id}-full") |> render_click()
    refute has_element?(view, "#sub-task-#{long.id}-body.task-body-clamped")
    assert has_element?(view, "#sub-task-#{long.id}-full", "Collapse")

    # opening a different task resets the clamp
    view |> element("#sub-task-#{short.id}-toggle") |> render_click()
    view |> element("#sub-task-#{long.id}-toggle") |> render_click()
    assert has_element?(view, "#sub-task-#{long.id}-body.task-body-clamped")
    assert has_element?(view, "#sub-task-#{long.id}-full", "Show all 32 lines")
  end

  test "a drawer opened with no active run has every task collapsed", ctx do
    view = open(ctx.conn, ctx.board, ctx.card)

    refute has_element?(view, "#card-plan-tasks [id$='-body']")
    refute has_element?(view, "[id$='-agent-here']")
  end

  test "drawer open with an active run auto-opens the in-flight task and marks it", ctx do
    [_long, short, third, _none] = ctx.tasks
    active_run(ctx.board, ctx.card, short)
    view = open(ctx.conn, ctx.board, ctx.card)

    assert has_element?(view, "#sub-task-#{short.id}-body", "Just one line.")
    assert has_element?(view, "#sub-task-#{short.id}[data-in-flight='true']")
    assert has_element?(view, "#sub-task-#{short.id}-agent-here", "AGENT IS HERE")
    refute has_element?(view, "#sub-task-#{third.id}-body")
    refute has_element?(view, "#sub-task-#{third.id}-agent-here")
  end

  test "when the run's binding advances, the new task opens and the finished one collapses", ctx do
    [_long, short, third, _none] = ctx.tasks
    run = active_run(ctx.board, ctx.card, short)
    view = open(ctx.conn, ctx.board, ctx.card)
    assert has_element?(view, "#sub-task-#{short.id}-body")

    bind(run, third)
    run_refresh(view, ctx.card)

    assert has_element?(view, "#sub-task-#{third.id}-body", "Third body.")
    assert has_element?(view, "#sub-task-#{third.id}-agent-here")
    refute has_element?(view, "#sub-task-#{short.id}-body")
    refute has_element?(view, "#sub-task-#{short.id}-agent-here")
  end

  test "a reader's manual toggle survives a refresh that doesn't change the in-flight task", ctx do
    [long, short, _third, _none] = ctx.tasks
    active_run(ctx.board, ctx.card, short)
    view = open(ctx.conn, ctx.board, ctx.card)

    view |> element("#sub-task-#{long.id}-toggle") |> render_click()
    assert has_element?(view, "#sub-task-#{long.id}-body")

    # the run path …
    run_refresh(view, ctx.card)
    assert has_element?(view, "#sub-task-#{long.id}-body")
    refute has_element?(view, "#sub-task-#{short.id}-body")

    # … and the card_upserted path (refresh_card/2). Reload first: update_card broadcasts the
    # struct it is handed, and ctx.card predates add_tasks (its sub_tasks are []).
    {:ok, _} = ctx.board |> Cards.get_card(ctx.card.id) |> Cards.update_card(%{title: "Accordion renamed"})
    render(view)
    assert has_element?(view, "#sub-task-#{long.id}-body")
    assert has_element?(view, "#sub-task-#{short.id}-agent-here")
  end

  test "switching cards resets the accordion to the new card's in-flight task", ctx do
    [long | _] = ctx.tasks
    code = Enum.find(ctx.board.stages, &(&1.name == "Code"))
    {:ok, other} = Cards.create_card(code, %{title: "Other"})
    {:ok, [other_task]} = Cards.add_tasks(other, [%{title: "Other task", body: "Other body."}])
    active_run(ctx.board, other, other_task)

    view = open(ctx.conn, ctx.board, ctx.card)
    view |> element("#sub-task-#{long.id}-toggle") |> render_click()

    render_patch(view, ~p"/board/#{ctx.board.slug}?card=#{Cards.ref(ctx.board, other)}")
    render_async(view)

    assert has_element?(view, "#sub-task-#{other_task.id}-body", "Other body.")
    assert has_element?(view, "#sub-task-#{other_task.id}-agent-here")
  end
end
