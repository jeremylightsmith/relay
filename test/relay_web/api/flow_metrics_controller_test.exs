defmodule RelayWeb.Api.FlowMetricsControllerTest do
  use RelayWeb.ConnCase, async: true

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board}
  end

  test "returns summary + nodes with cost null when blank", %{conn: conn, board: board} do
    insert(:flow, board: board, key: "code", nodes: [%Schemas.Flow.Node{key: "implement", type: :agent, model: "sonnet"}])
    card = insert(:card, board: board, stage: insert(:stage, board: board))
    run = insert(:run, card: card, flow_key: "code", status: :done)
    insert(:node_execution, run: run, node: "implement", duration_s: 60, cost: nil)

    body = conn |> get(~p"/api/flows/code/metrics") |> json_response(200) |> Map.fetch!("data")

    assert %{"total_runs" => 1, "completed" => 1} = body["summary"]
    assert [node] = body["nodes"]
    assert node["node_key"] == "implement"
    assert node["runs"] == 1
    assert node["cost_p50"] == nil
    assert node["cost_p95"] == nil
    assert is_map(node["verdict_split"])
    assert Map.has_key?(node, "loop_laps")
  end

  test "honors the window param", %{conn: conn, board: board} do
    insert(:flow, board: board, key: "code", nodes: [%Schemas.Flow.Node{key: "implement", type: :agent}])
    body = conn |> get(~p"/api/flows/code/metrics?window=7d") |> json_response(200) |> Map.fetch!("data")
    assert body["nodes"] == []
  end

  test "404s an unknown flow key", %{conn: conn} do
    assert conn |> get(~p"/api/flows/nope/metrics") |> json_response(404)
  end
end
