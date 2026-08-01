defmodule RelayWeb.FlowEditorExpectsCommitsTest do
  @moduledoc """
  RLY-241 §4. The editor's working copy is built with `Map.take(node, <field list>)`; a field
  list that omits `expects_commits` drops it on load, so the save rebuilds the embeds without
  it and it falls back to `false` — silently disarming RLY-194's no-commits-means-failed guard
  on all four commit-producing Code nodes. A save that changes nothing must change nothing.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Flows

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  test "saving the Code flow with an untouched definition preserves expects_commits on every commit-producing node",
       %{conn: conn, board: board} do
    marked = fn flow ->
      flow.nodes |> Enum.filter(& &1.expects_commits) |> Enum.map(& &1.key) |> Enum.sort()
    end

    before = marked.(Flows.get_flow!(board, "code"))
    assert before == ["acceptance_fix", "final_fix", "implement", "smoke_fix"]

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code")

    # The editor only renders "#flow-editor-save" once something is dirty (there is no
    # "click Save with a pristine working copy" affordance), so we mark the editor dirty via
    # a TRIGGER-only change — which does not touch nodes/edges and saves directly (no confirm
    # modal, no version bump, per the "editing a trigger stage..." test in
    # flow_editor_live_test.exs) — while still pushing the (buggy, field-stripped) working
    # copy's node list through `persist/1` exactly like any other save. This is the "unrelated,
    # unchanged-definition save" path the bug hits.
    code = Flows.get_flow!(board, "code")
    other = Enum.find(board.stages, &(&1.id != code.pulls_from_stage_id))

    view
    |> element("#trigger-pulls-from")
    |> render_change(%{"stage_id" => to_string(other.id)})

    view |> element("#flow-editor-save") |> render_click()

    assert marked.(Flows.get_flow!(board, "code")) == before
  end

  test "an unrelated definition edit still preserves expects_commits", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code")

    render_hook(view, "edit_node_field", %{"key" => "post", "field" => "model", "value" => "opus"})
    view |> element("#flow-editor-save") |> render_click()
    view |> element("#flow-save-confirm") |> render_click()

    code = Flows.get_flow!(board, "code")
    assert Enum.find(code.nodes, &(&1.key == "post")).model == "opus"

    assert code.nodes |> Enum.filter(& &1.expects_commits) |> Enum.map(& &1.key) |> Enum.sort() ==
             ["acceptance_fix", "final_fix", "implement", "smoke_fix"]
  end

  test "saving the Plan flow with an untouched definition preserves the card contract (RE244)", %{
    conn: conn,
    board: board
  } do
    contract = fn flow ->
      node = Enum.find(flow.nodes, &(&1.key == "write_plan"))
      {node.reads, node.writes}
    end

    before = contract.(Flows.get_flow!(board, "plan"))
    assert before == {[:spec, :acceptance_criteria], [:plan]}

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/plan")

    plan = Flows.get_flow!(board, "plan")
    other = Enum.find(board.stages, &(&1.id != plan.pulls_from_stage_id))

    view |> element("#trigger-pulls-from") |> render_change(%{"stage_id" => to_string(other.id)})
    view |> element("#flow-editor-save") |> render_click()

    assert contract.(Flows.get_flow!(board, "plan")) == before
  end
end
