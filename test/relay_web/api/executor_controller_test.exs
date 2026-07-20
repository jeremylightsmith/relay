defmodule RelayWeb.Api.ExecutorControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards
  alias Relay.Runs

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
    assert body["freshness"] == "fresh"
    assert body["stale?"] == false
    assert body["version"] == Runs.min_executor_version()
    assert body["outdated"] == false
    assert body["jobs"] == []
    assert body["last_heartbeat"]
  end

  test "an executor below the minimum version is flagged outdated, independent of freshness", %{
    conn: conn,
    board: board
  } do
    insert(:executor, board: board, name: "old-timer", version: Runs.min_executor_version() - 1)

    [body] = conn |> get(~p"/api/executors") |> json_response(200) |> Map.fetch!("data")

    assert body["freshness"] == "fresh"
    assert body["outdated"] == true
  end

  test "an executor silent past the reclaim threshold is gone, and marked stale", %{conn: conn, board: board} do
    old = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -3600, :second)
    insert(:executor, board: board, name: "ghost", last_heartbeat: old)

    [body] = conn |> get(~p"/api/executors") |> json_response(200) |> Map.fetch!("data")

    assert body["freshness"] == "gone"
    assert body["stale?"] == true
  end

  test "an executor that has missed one beat but isn't reclaimable yet is merely stale", %{conn: conn, board: board} do
    # interval: 30 -> fresh through 45s, gone past 60s (max(60, 2 * 30)). 50s lands in the
    # untested middle: a missed beat, but the reaper has not touched its work yet.
    borderline = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -50, :second)
    insert(:executor, board: board, name: "flaky", interval: 30, last_heartbeat: borderline)

    [body] = conn |> get(~p"/api/executors") |> json_response(200) |> Map.fetch!("data")

    assert body["freshness"] == "stale"
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
    assert job["ref"] == Cards.ref(board, card)
  end

  test "another board's executors never appear", %{conn: conn} do
    other = insert(:board, key: "OTH")
    insert(:executor, board: other, name: "theirs")

    assert conn |> get(~p"/api/executors") |> json_response(200) |> Map.fetch!("data") == []
  end
end
