defmodule RelayWeb.BoardStoppedWorkTest do
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    Relay.Runs.Capacity.reset()
    board = insert(:board, owner: user)
    insert(:membership, board: board, user: user)
    queue = insert(:stage, board: board, name: "Plan:Done", position: 1, type: :queue)
    works = insert(:stage, board: board, name: "Code", position: 2, type: :work, ai_enabled: true)
    insert(:flow, board: board, key: "code", enabled: true, pulls_from_stage_id: queue.id, works_in_stage_id: works.id)
    {:ok, board: board, works: works}
  end

  defp queued_job(works, age_s) do
    at = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -age_s, :second)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running)
    exec = insert(:node_execution, run: run, outcome: nil, finished_at: nil, inserted_at: at)
    insert(:node_job, node_execution: exec, state: :queued, executor_name: nil, claimed_at: nil, inserted_at: at)
  end

  test "shows the banner naming the outdated reason when work is stopped", %{conn: conn, board: board, works: works} do
    queued_job(works, 600)
    insert(:executor, board: board, name: "old", version: 0)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "#stopped-work-banner")
    assert render(view) =~ "requires v#{Relay.Runs.min_executor_version()}"
  end

  test "stays quiet on a healthy board", %{conn: conn, board: board, works: works} do
    insert(:executor, board: board, name: "live", version: Relay.Runs.min_executor_version())
    insert(:card, stage: works, status: :working)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    refute has_element?(view, "#stopped-work-banner")
  end
end
