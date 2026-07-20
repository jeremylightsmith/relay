defmodule RelayWeb.Api.ExecutorControllerTest do
  use RelayWeb.ConnCase, async: true

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board}
  end

  test "lists the board's executors with advertised capacity and heartbeat", %{conn: conn, board: board} do
    insert(:executor, board: board, name: "mac", host: "mac.local", capacity: %{"shared_clean" => 3, "exclusive" => 1})

    [body] = conn |> get(~p"/api/executors") |> json_response(200) |> Map.fetch!("data")

    assert body["name"] == "mac"
    assert body["host"] == "mac.local"
    assert body["capacity"] == %{"shared_clean" => 3, "exclusive" => 1}
    assert body["stale?"] == false
    assert body["jobs"] == []
    assert body["last_heartbeat"]
  end

  test "a silent executor is marked stale", %{conn: conn, board: board} do
    old = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -3600, :second)
    insert(:executor, board: board, name: "ghost", last_heartbeat: old)

    [body] = conn |> get(~p"/api/executors") |> json_response(200) |> Map.fetch!("data")

    assert body["stale?"] == true
  end

  test "the jobs an executor holds are listed", %{conn: conn, board: board} do
    stage = insert(:stage, board: board, position: 1)
    card = insert(:card, stage: stage)
    run = insert(:run, card: card)
    execution = insert(:node_execution, run: run, node_key: "implement")
    insert(:node_job, node_execution: execution, state: :running, executor_name: "mac")
    insert(:executor, board: board, name: "mac")

    [body] = conn |> get(~p"/api/executors") |> json_response(200) |> Map.fetch!("data")

    assert [job] = body["jobs"]
    assert job["node_key"] == "implement"
    assert job["state"] == "running"
  end

  test "another board's executors never appear", %{conn: conn} do
    other = insert(:board, key: "OTH")
    insert(:executor, board: other, name: "theirs")

    assert conn |> get(~p"/api/executors") |> json_response(200) |> Map.fetch!("data") == []
  end
end
