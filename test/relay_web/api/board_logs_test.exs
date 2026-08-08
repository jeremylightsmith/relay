defmodule RelayWeb.Api.BoardLogsTest do
  # NOT `async: true`, under ADR 0009 rule 1's sanctioned exception: a process-global singleton
  # with no instance seam. `POST /api/board/logs` -> `AgentLog.record/2` always enqueues onto the
  # app-wide `Relay.Activity.LogSink` (unlike `log_sink_test.exs` and
  # `log_sink_resilience_test.exs`, which start their own sink and are async).
  #
  # `allow!/1` cannot buy async here, and this module tried it and raced (RE298): `Sandbox.allow/3`
  # binds a pid to exactly ONE connection, so when two tests overlap the second gets
  # `{:already, :allowed}` and the sink stays on the FIRST test's connection. `LogSink`'s
  # ref -> card_id lookup then cannot see this test's card, resolves to `[]`, and the flush
  # inserts and broadcasts nothing — raising nothing and logging nothing. The test just never
  # receives its broadcast. Shared mode is the documented fallback for a singleton like this;
  # async needs an injectable sink on the HTTP path, which is a production change, not a test one.
  use RelayWeb.ConnCase, async: false

  import Ecto.Query

  alias Relay.Activity.LogSink
  alias Relay.AgentLog
  alias Relay.Repo

  setup %{conn: conn} do
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
