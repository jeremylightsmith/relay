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
end
