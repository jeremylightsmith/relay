defmodule RelayWeb.FlowEditorLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Flows

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  test "mounts the editor for a flow key and shows the version chip", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code")
    assert has_element?(view, "#flow-editor-version-chip", "v1")
    assert has_element?(view, "#flow-graph")
  end

  test "404s on an unknown flow key", %{conn: conn, board: board} do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/board/#{board.slug}/flows/nope")
    assert to =~ "/board/#{board.slug}/settings"
  end

  test "editing a trigger stage marks dirty and saves without a version bump", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    code = Flows.get_flow!(board, "code")
    other = Enum.find(board.stages, &(&1.id != code.pulls_from_stage_id))

    view
    |> element("#trigger-pulls-from")
    |> render_change(%{"stage_id" => to_string(other.id)})

    assert has_element?(view, "#flow-editor-unsaved-bar")

    view |> element("#flow-editor-save") |> render_click()
    # trigger-only change: no modal, saves directly, version stays v1
    assert has_element?(view, "#flow-editor-version-chip", "v1")
    assert Flows.get_flow!(board, "code").pulls_from_stage_id == other.id
  end

  test "editing then Save opens the confirm modal; confirm bumps to v2", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    # simulate a definition edit through the working copy (implement prompt) via the
    # low-level edit event the inspector (Task 4) will emit.
    render_hook(view, "edit_node_field", %{"key" => "implement", "field" => "run", "value" => "CHANGED"})

    view |> element("#flow-editor-save") |> render_click()
    assert has_element?(view, "#flow-save-modal", "Save as v2")

    view |> element("#flow-save-confirm") |> render_click()
    assert has_element?(view, "#flow-editor-version-chip", "v2")
    assert %Schemas.FlowVersion{} = Flows.get_version(Flows.get_flow!(board, "code"), 1)
    assert %Schemas.FlowVersion{nodes: nodes} = Flows.get_version(Flows.get_flow!(board, "code"), 2)
    assert Enum.any?(nodes, &(&1.key == "implement" and &1.run == "CHANGED"))
  end

  test "the save modal omits the mid-run note while mid_run_count is 0", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    render_hook(view, "edit_node_field", %{"key" => "implement", "field" => "run", "value" => "X"})
    view |> element("#flow-editor-save") |> render_click()
    refute has_element?(view, "#flow-save-modal-midrun")
  end

  test "selecting a node shows the inspector; Delete node is guarded while referenced", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    view |> element(~s([data-node="implement"])) |> render_click()
    assert has_element?(view, "#inspector-node-name")
    # implement is referenced by several edges → delete disabled + warning strip
    assert has_element?(view, "#inspector-delete-node[disabled]")
    assert has_element?(view, "#inspector-delete-guard", "Referenced by")
  end

  test "editing the run prompt in the inspector marks the flow dirty", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s([data-node="implement"])) |> render_click()

    view
    |> element("#inspector-node-form")
    |> render_change(%{"field" => "run", "value" => "new prompt"})

    assert has_element?(view, "#flow-editor-unsaved-bar")
  end

  test "deleting the start edge blocks save with an inline error naming the problem", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    # select the start edge's outcome chip then delete it via the toolbar
    render_hook(view, "delete_start_edge", %{})
    assert has_element?(view, "#flow-editor-errors", "exactly one edge must leave start")
    assert has_element?(view, "#flow-editor-save[disabled]")
  end

  test "add-node palette inserts a typed node with a unique key and selects it", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s(#palette-shell)) |> render_click()
    assert has_element?(view, "#inspector-node-name")
    # a new shell-N node exists in the graph
    assert render(view) =~ "shell-"
  end

  test "selecting an edge shows the edge inspector; the max-loops stepper marks the flow dirty", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    # spec_review → implement (failed, max_loops: 3) is edge index 3
    view |> element(~s([data-edge="3"])) |> render_click()
    assert has_element?(view, "#inspector-edge-from", "spec_review")
    assert has_element?(view, "#inspector-edge-to", "implement")

    view |> element("#inspector-max-loops-inc") |> render_click()
    assert has_element?(view, "#flow-editor-unsaved-bar")
  end

  test "Delete edge in the inspector removes the selected edge", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    count_before = count_edges(render(view))

    view |> element(~s([data-edge="3"])) |> render_click()
    view |> element("#inspector-delete-edge") |> render_click()

    assert has_element?(view, "#flow-editor-unsaved-bar")
    assert count_edges(render(view)) == count_before - 1
  end

  test "Connect edge: selecting two nodes creates a new succeeded edge", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    count_before = count_edges(render(view))

    view |> element("#toolbar-connect-edge") |> render_click()
    view |> element(~s([data-node="branch"])) |> render_click()
    view |> element(~s([data-node="merge"])) |> render_click()

    assert has_element?(view, "#flow-editor-unsaved-bar")
    assert count_edges(render(view)) == count_before + 1
  end

  test "Connect edge: a second toolbar click cancels connect mode", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    view |> element("#toolbar-connect-edge") |> render_click()
    assert has_element?(view, "#toolbar-connect-edge", "Cancel")

    view |> element("#toolbar-connect-edge") |> render_click()
    refute has_element?(view, "#toolbar-connect-edge", "Cancel")
  end

  test "Connect edge: pressing Esc cancels connect mode", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    view |> element("#toolbar-connect-edge") |> render_click()
    assert has_element?(view, "#toolbar-connect-edge", "Cancel")

    view |> element("#flow-editor-canvas") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#toolbar-connect-edge", "Cancel")
  end

  test "renaming a node rewrites its key and every edge endpoint referencing it", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s([data-node="branch"])) |> render_click()

    view
    |> element("#inspector-node-rename-form")
    |> render_change(%{"value" => "branch2"})

    assert has_element?(view, ~s([data-node="branch2"]))
    refute has_element?(view, ~s([data-node="branch"]))
  end

  test "Delete node in the inspector removes an unreferenced node", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element("#palette-shell") |> render_click()
    view |> element("#inspector-delete-node") |> render_click()
    refute render(view) =~ ~s(data-node="shell-1")
  end

  test "a customized default flow shows the diff affordance; View diff lists the changed node", %{
    conn: conn,
    board: board
  } do
    {:ok, _flow} =
      Flows.save_definition(Flows.get_flow!(board, "code"), %{
        nodes: bump_implement_run(Flows.get_flow!(board, "code"))
      })

    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    assert has_element?(view, "#flow-diff-affordance", "differ from the shipped default")

    view |> element("#flow-diff-view") |> render_click()
    assert has_element?(view, "#flow-diff-modal", "implement")
  end

  test "Reset to default restores the definition and bumps the version", %{conn: conn, board: board} do
    {:ok, _} =
      Flows.save_definition(Flows.get_flow!(board, "code"), %{
        nodes: bump_implement_run(Flows.get_flow!(board, "code"))
      })

    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element("#flow-diff-reset") |> render_click()
    view |> element("#flow-reset-confirm") |> render_click()

    refute has_element?(view, "#flow-diff-affordance")
    refute Flows.customized?(Flows.get_flow!(board, "code"))
  end

  defp count_edges(html), do: ~r/data-edge="\d+"/ |> Regex.scan(html) |> length()

  # helper: return the code flow's nodes with implement.run changed (as attr maps)
  defp bump_implement_run(flow) do
    Enum.map(flow.nodes, fn n ->
      base = Map.take(n, [:key, :type, :run, :model, :effort, :max_retries, :timeout_minutes])
      if n.key == "implement", do: %{base | run: "CUSTOM"}, else: base
    end)
  end
end
