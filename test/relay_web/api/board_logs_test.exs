defmodule RelayWeb.Api.BoardLogsTest do
  use RelayWeb.ConnCase, async: true

  import Ecto.Query

  alias Relay.Activity.LogSink
  alias Relay.AgentLog
  alias Relay.Repo

  # RE298 / ADR 0009 rule 2: `POST /api/board/logs` -> `AgentLog.record/2` always enqueues onto
  # the app-wide `Relay.Activity.LogSink` (no injectable sink on this path — unlike
  # `log_sink_test.exs`, which starts its own). `allow!/1` grants that single global process
  # access to this test's sandbox connection for the life of the test; the ref -> card_id lookup
  # inside `LogSink` only ever resolves cards visible in the connection it currently holds, so a
  # concurrently-running test's entries simply fail to resolve and get dropped (logged, not
  # inserted) rather than leaking across tests.
  setup %{conn: conn} do
    allow!(Process.whereis(LogSink))

    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), board: board}
  end

  defp post_logs(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/board/logs", Jason.encode!(payload))
  end

  # Drive the app-started sink's debounce window to completion without sleeping.
  defp settle do
    sink = Process.whereis(LogSink)
    :sys.get_state(sink)
    send(sink, :flush)
    :sys.get_state(sink)
    :ok
  end

  test "POST /api/board/logs broadcasts each entry and returns 200", %{conn: conn, board: board} do
    AgentLog.subscribe(board.id)

    conn =
      post_logs(conn, [
        %{"ref" => "RL1", "kind" => "lifecycle", "text" => "started"},
        %{"ref" => "RL1", "kind" => "claude", "text" => "thinking"}
      ])

    assert response(conn, 200)
    assert_receive {:agent_log, %{text: "started", kind: :lifecycle, ref: "RL1"}}
    assert_receive {:agent_log, %{text: "thinking", kind: :claude}}
  end

  test "a ref-tagged line is persisted onto its card", %{conn: conn, board: board} do
    card = insert(:card, stage: insert(:stage, board: board), ref_number: 7)

    assert response(post_logs(conn, [%{"ref" => "RL7", "kind" => "claude", "text" => "🔧 Edit"}]), 200)
    :ok = settle()

    assert [row] = Repo.all(from a in Schemas.Activity, where: a.card_id == ^card.id)
    assert row.text == "🔧 Edit"
    assert row.type == :action
  end

  # Q7→A: board-level lines have no card, and stay ephemeral.
  test "a ref-less board-level line is broadcast but never persisted", %{conn: conn, board: board} do
    AgentLog.subscribe(board.id)

    assert response(post_logs(conn, [%{"kind" => "lifecycle", "text" => "scanning board"}]), 200)
    :ok = settle()

    assert_receive {:agent_log, %{text: "scanning board", ref: nil}}
    assert Repo.aggregate(from(a in Schemas.Activity, where: a.text == "scanning board"), :count) == 0
  end

  test "a node_job_id on a log line is persisted and broadcast", %{conn: conn, board: board} do
    card = insert(:card, stage: insert(:stage, board: board), ref_number: 7)
    Relay.Events.subscribe(board.id)

    assert response(
             post_logs(conn, [%{"kind" => "claude", "ref" => "RL7", "text" => "working", "node_job_id" => "812"}]),
             200
           )

    :ok = settle()

    assert_receive {:card_log_appended, card_id, [row]} when card_id == card.id
    assert row.node_job_id == "812"
    assert Repo.get_by!(Schemas.Activity, card_id: card.id).node_job_id == "812"
  end

  test "an unauthenticated POST is rejected with 401" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/board/logs", Jason.encode!([%{"text" => "x"}]))

    assert json_response(conn, 401)
  end
end
