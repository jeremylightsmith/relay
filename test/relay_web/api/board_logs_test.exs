defmodule RelayWeb.Api.BoardLogsTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.AgentLog

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), board: board}
  end

  test "POST /api/board/logs broadcasts each entry and returns 200", %{conn: conn, board: board} do
    AgentLog.subscribe(board.id)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/board/logs",
        Jason.encode!([
          %{"ref" => "RLY-1", "kind" => "lifecycle", "text" => "started"},
          %{"ref" => "RLY-1", "kind" => "claude", "text" => "thinking"}
        ])
      )

    assert response(conn, 200)
    assert_receive {:agent_log, %{text: "started", kind: :lifecycle, ref: "RLY-1"}}
    assert_receive {:agent_log, %{text: "thinking", kind: :claude}}
  end

  test "an unauthenticated POST is rejected with 401" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/board/logs", Jason.encode!([%{"text" => "x"}]))

    assert json_response(conn, 401)
  end
end
