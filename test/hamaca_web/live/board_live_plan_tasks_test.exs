defmodule HamacaWeb.BoardLivePlanAndTasksTest do
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Repo
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
  # `Hamaca.Runs.in_flight_sub_task_id/1` reads.
  defp active_run(board, card, task) do
    # Its own stage, positioned past the default board's: the stage factory's global position
    # sequence otherwise collides with stages 1..8 depending on how many stages ran before.
    stage =
      insert(:stage,
        board: board,
        type: :work,
        category: :in_progress,
        position: 1000 + System.unique_integer([:positive])
      )

    flow =
      insert(:flow,
        board: board,
        stage: stage,
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

  describe "RE507 human task editing" do
    defp ids(card), do: card |> Cards.list_tasks() |> Enum.map(& &1.id)
    defp titles(card), do: card |> Cards.list_tasks() |> Enum.map(& &1.title)

    defp click(view, selector), do: view |> element(selector) |> render_click()

    defp open_menu(view, task), do: click(view, "#sub-task-#{task.id}-menu-btn")

    defp start_edit(view, task) do
      open_menu(view, task)
      click(view, "#sub-task-#{task.id}-menu-edit")
    end

    defp open_confirm(view, task) do
      open_menu(view, task)
      click(view, "#sub-task-#{task.id}-menu-delete")
    end

    @locked_flash "Tasks are read-only while the agent works them."

    test "scenario 1: Enter keeps adding, the add row re-mounts keyed on the count", ctx do
      view = open(ctx.conn, ctx.board, ctx.card)

      click(view, "#card-plan-add-task")
      view |> form("#card-plan-add-form", %{"task" => %{"title" => "First"}}) |> render_submit()
      view |> form("#card-plan-add-form", %{"task" => %{"title" => "Second"}}) |> render_submit()

      tasks = Cards.list_tasks(ctx.card)
      assert tasks |> Enum.map(& &1.title) |> Enum.take(-2) == ["First", "Second"]
      assert tasks |> Enum.take(-2) |> Enum.map(& &1.position) == [4, 5]
      assert has_element?(view, "#card-plan-add-form")
      assert has_element?(view, "#card-plan-add-input-6")
      refute has_element?(view, "#card-plan-add-task")
    end

    test "scenario 2: a blank add stops adding without writing or erroring", ctx do
      view = open(ctx.conn, ctx.board, ctx.card)

      click(view, "#card-plan-add-task")
      html = view |> form("#card-plan-add-form", %{"task" => %{"title" => "   "}}) |> render_submit()

      assert Cards.task_count(ctx.card) == 4
      refute has_element?(view, "#card-plan-add-form")
      assert has_element?(view, "#card-plan-add-task")
      refute html =~ "can&#39;t be blank"
      refute has_element?(view, "#flash-error")
    end

    test "scenario 3: cancel closes the add row and adds nothing", ctx do
      view = open(ctx.conn, ctx.board, ctx.card)

      click(view, "#card-plan-add-task")
      click(view, "#card-plan-add-cancel")

      refute has_element?(view, "#card-plan-add-form")
      assert Cards.task_count(ctx.card) == 4
    end

    test "scenario 4: the ⋯ button toggles its menu", ctx do
      [_long, short, _third, _none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      open_menu(view, short)
      assert has_element?(view, "#sub-task-#{short.id}-menu")

      open_menu(view, short)
      refute has_element?(view, "#sub-task-#{short.id}-menu")
    end

    test "scenario 4: close_task_menu closes the open menu", ctx do
      [_long, short, _third, _none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      open_menu(view, short)
      render_click(view, "close_task_menu", %{})
      refute has_element?(view, "#sub-task-#{short.id}-menu")
    end

    test "scenario 5: Edit opens the in-row editor and Save writes title and body", ctx do
      [_long, short, _third, _none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      start_edit(view, short)
      assert has_element?(view, "#sub-task-#{short.id}-edit-form")
      assert has_element?(view, ~s(#sub-task-#{short.id}-title-input[value="Short task"]))
      refute has_element?(view, "#sub-task-#{short.id}-menu")

      view
      |> form("#sub-task-#{short.id}-edit-form", %{
        "id" => "#{short.id}",
        "task" => %{"title" => "Short (edited)", "body" => "Some **markdown**"}
      })
      |> render_submit()

      refute has_element?(view, "#sub-task-#{short.id}-edit-form")
      assert has_element?(view, "li#sub-task-#{short.id}[data-open='true']")
      assert has_element?(view, "#sub-task-#{short.id}-title", "Short (edited)")
      assert has_element?(view, "#sub-task-#{short.id}-meta", "1 line")
      assert %{title: "Short (edited)", body: "Some **markdown**"} = Repo.get!(SubTask, short.id)
    end

    test "scenario 5: Edit opens the row", ctx do
      [_long, short, _third, _none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      start_edit(view, short)
      view |> element("#sub-task-#{short.id}-cancel") |> render_click()
      assert has_element?(view, "li#sub-task-#{short.id}[data-open='true']")
    end

    test "scenario 6: a blank title keeps the editor with the error; Cancel discards", ctx do
      [_long, short, _third, _none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      start_edit(view, short)

      view
      |> form("#sub-task-#{short.id}-edit-form", %{"id" => "#{short.id}", "task" => %{"title" => "", "body" => ""}})
      |> render_submit()

      assert has_element?(view, "#sub-task-#{short.id}-edit-form", "can't be blank")

      click(view, "#sub-task-#{short.id}-cancel")
      refute has_element?(view, "#sub-task-#{short.id}-edit-form")
      assert Repo.get!(SubTask, short.id).title == "Short task"
      assert has_element?(view, "#sub-task-#{short.id}-title", "Short task")
    end

    test "scenario 7: one edit at a time; a body-less task's textarea is empty", ctx do
      [_long, short, _third, none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      start_edit(view, short)
      start_edit(view, none)

      assert has_element?(view, "#sub-task-#{none.id}-edit-form")
      refute has_element?(view, "#sub-task-#{short.id}-edit-form")
      assert view |> element("#sub-task-#{none.id}-body-input") |> render() =~ ~r/<textarea[^>]*>\s*<\/textarea>/
    end

    test "scenario 8: Move to top / Move to bottom reorder", ctx do
      [long, short, third, none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      open_menu(view, third)
      click(view, "#sub-task-#{third.id}-menu-top")
      assert ids(ctx.card) == [third.id, long.id, short.id, none.id]
      refute has_element?(view, "#sub-task-#{third.id}-menu")

      open_menu(view, third)
      click(view, "#sub-task-#{third.id}-menu-bottom")
      assert ids(ctx.card) == [long.id, short.id, none.id, third.id]
    end

    test "scenario 9: the hook's move_task takes integers or strings", ctx do
      [long, short, third, none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      render_hook(view, "move_task", %{"id" => long.id, "to_position" => 1})
      assert ids(ctx.card) == [short.id, long.id, third.id, none.id]

      render_hook(view, "move_task", %{"id" => "#{long.id}", "to_position" => "0"})
      assert ids(ctx.card) == [long.id, short.id, third.id, none.id]
    end

    test "scenario 9: a move rerenders the drawer in the new order", ctx do
      [long, short, _third, _none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      render_hook(view, "move_task", %{"id" => long.id, "to_position" => 1})
      assert has_element?(view, "#card-plan-tasks li:nth-child(1)#sub-task-#{short.id}")
      assert has_element?(view, "#card-plan-tasks li:nth-child(2)#sub-task-#{long.id}")
    end

    test "scenario 10: Delete task… shows the confirm; Cancel keeps the row", ctx do
      [long | _] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      open_confirm(view, long)
      assert has_element?(view, "#sub-task-#{long.id}-confirm", "and its 32-line body?")

      click(view, "#sub-task-#{long.id}-delete-cancel")
      refute has_element?(view, "#sub-task-#{long.id}-confirm")
      assert has_element?(view, "li#sub-task-#{long.id}")
    end

    test "scenario 11: Esc closes the confirm and leaves the drawer open", ctx do
      [long | _] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      open_confirm(view, long)
      render_hook(view, "close_drawer", %{"key" => "Escape"})

      refute has_element?(view, "#sub-task-#{long.id}-confirm")
      assert has_element?(view, "#card-drawer-panel")
    end

    test "scenario 11: Esc closes the menu and leaves the drawer open", ctx do
      [long | _] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      open_menu(view, long)
      render_hook(view, "close_drawer", %{"key" => "Escape"})

      refute has_element?(view, "#sub-task-#{long.id}-menu")
      assert has_element?(view, "#card-drawer-panel")
    end

    test "scenario 12: confirming deletes the row and updates the count", ctx do
      [long | _] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)

      open_confirm(view, long)
      click(view, "#sub-task-#{long.id}-delete-confirm")

      refute has_element?(view, "li#sub-task-#{long.id}")
      assert Cards.task_count(ctx.card) == 3
      assert has_element?(view, "#card-plan-count", "0/3")
    end

    test "scenario 13: a running run locks the list; toggle and check still work", ctx do
      [long, short, _third, _none] = ctx.tasks
      active_run(ctx.board, ctx.card, short)
      view = open(ctx.conn, ctx.board, ctx.card)

      assert has_element?(view, "#card-plan-locked")
      refute has_element?(view, "[id$='-menu-btn']")
      refute has_element?(view, "[id$='-grip']")
      refute has_element?(view, "#card-plan-add-task")

      click(view, "#sub-task-#{long.id}-toggle")
      assert has_element?(view, "li#sub-task-#{long.id}[data-open='true']")

      click(view, "#sub-task-#{long.id}-check")
      assert Repo.get!(SubTask, long.id).done
    end

    test "scenario 14: a stale page's writes during a running run are refused", ctx do
      [long, short, _third, _none] = ctx.tasks
      active_run(ctx.board, ctx.card, short)
      view = open(ctx.conn, ctx.board, ctx.card)
      before = ids(ctx.card)

      assert render_click(view, "delete_task", %{"id" => "#{long.id}"}) =~ @locked_flash
      assert render_click(view, "move_task", %{"id" => "#{long.id}", "to_position" => "3"}) =~ @locked_flash

      assert render_hook(view, "save_task", %{"id" => "#{long.id}", "task" => %{"title" => "X", "body" => ""}}) =~
               @locked_flash

      assert render_hook(view, "save_new_task", %{"task" => %{"title" => "Y"}}) =~ @locked_flash

      assert ids(ctx.card) == before
      assert Repo.get!(SubTask, long.id).title == "Long task"
    end

    test "scenario 14: the openers are refused during a running run", ctx do
      [long, short, _third, _none] = ctx.tasks
      active_run(ctx.board, ctx.card, short)
      view = open(ctx.conn, ctx.board, ctx.card)

      for {event, params} <- [
            {"edit_task", %{"id" => "#{long.id}"}},
            {"open_task_menu", %{"id" => "#{long.id}"}},
            {"confirm_delete_task", %{"id" => "#{long.id}"}},
            {"start_add_task", %{}}
          ] do
        assert render_click(view, event, params) =~ @locked_flash
      end

      refute has_element?(view, "[id$='-edit-form']")
      refute has_element?(view, "#card-plan-add-form")
    end

    test "scenario 15: a parked run leaves the list editable", ctx do
      [_long, short, _third, _none] = ctx.tasks
      run = active_run(ctx.board, ctx.card, short)
      {:ok, _} = run |> Ecto.Changeset.change(status: :parked) |> Repo.update()
      view = open(ctx.conn, ctx.board, ctx.card)

      for task <- ctx.tasks, do: assert(has_element?(view, "#sub-task-#{task.id}-menu-btn"))
      assert has_element?(view, "#card-plan-add-task")
      refute has_element?(view, "#card-plan-locked")
    end

    test "scenario 16: a run starting closes the editor; parking it unlocks", ctx do
      [_long, short, _third, _none] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)
      start_edit(view, short)
      assert has_element?(view, "#sub-task-#{short.id}-edit-form")

      run = active_run(ctx.board, ctx.card, short)
      run_refresh(view, ctx.card)

      refute has_element?(view, "#sub-task-#{short.id}-edit-form")
      assert has_element?(view, "#card-plan-locked")

      {:ok, _} = run |> Ecto.Changeset.change(status: :parked) |> Repo.update()
      run_refresh(view, ctx.card)

      refute has_element?(view, "#card-plan-locked")
      assert has_element?(view, "#sub-task-#{short.id}-menu-btn")
      # and the edit state was really cleared, not merely hidden
      refute has_element?(view, "#sub-task-#{short.id}-edit-form")
    end

    test "scenario 17: a concurrent delete of the confirmed task clears the confirm", ctx do
      [long | _] = ctx.tasks
      view = open(ctx.conn, ctx.board, ctx.card)
      open_confirm(view, long)

      {:ok, _} = Cards.delete_task(ctx.card, long.id)
      render(view)

      refute has_element?(view, "li#sub-task-#{long.id}")
      refute has_element?(view, "[id$='-confirm']")
      assert :sys.get_state(view.pid).socket.assigns.confirm_delete_task_id == nil

      click(view, "#card-plan-add-task")
      view |> form("#card-plan-add-form", %{"task" => %{"title" => "After"}}) |> render_submit()
      assert List.last(titles(ctx.card)) == "After"
    end

    test "scenario 18: an archived card's tasks are read-only without the run note", ctx do
      [long | _] = ctx.tasks
      {:ok, _} = Cards.archive_card(ctx.card)
      view = open(ctx.conn, ctx.board, ctx.card)

      assert has_element?(view, "li#sub-task-#{long.id}")
      refute has_element?(view, "[id$='-menu-btn']")
      refute has_element?(view, "#card-plan-add-task")
      refute has_element?(view, "#card-plan-locked")

      assert render_click(view, "delete_task", %{"id" => "#{long.id}"}) =~ "Archived cards are read-only."
      assert Cards.task_count(ctx.card) == 4
    end

    test "scenario 19: an empty Backlog card can add its first task", ctx do
      backlog = Enum.find(ctx.board.stages, &(&1.name == "Backlog"))
      {:ok, empty} = Cards.create_card(backlog, %{title: "Empty"})
      view = open(ctx.conn, ctx.board, empty)

      assert render(view) =~ "No plan yet"
      assert has_element?(view, "#card-plan-add-task")

      click(view, "#card-plan-add-task")
      view |> form("#card-plan-add-form", %{"task" => %{"title" => "Only"}}) |> render_submit()

      assert titles(empty) == ["Only"]
      assert has_element?(view, "#card-plan-count", "0/1")
    end

    test "a read-only board refuses save_new_task", ctx do
      {:ok, _} = Boards.archive_board(ctx.board)
      view = open(ctx.conn, ctx.board, ctx.card)

      assert render_hook(view, "save_new_task", %{"task" => %{"title" => "Nope"}}) =~
               "This board is archived (read-only)."

      assert Cards.task_count(ctx.card) == 4
    end
  end
end
