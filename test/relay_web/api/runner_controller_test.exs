defmodule RelayWeb.Api.RunnerControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards
  alias Relay.Runs

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board}
  end

  test "lists the board's runners with advertised capacity and heartbeat", %{conn: conn, board: board} do
    # Version stated here rather than taken from the factory's default: this test is about what
    # the route EXPOSES, so it must not move when a floor does (RE268 added a second one).
    insert(:runner,
      board: board,
      name: "mac",
      host: "mac.local",
      capacity: %{"shared_clean" => 3, "exclusive" => 1},
      version: Runs.min_runner_version()
    )

    [body] = conn |> get(~p"/api/runners") |> json_response(200) |> Map.fetch!("data")

    assert body["name"] == "mac"
    assert body["host"] == "mac.local"
    assert body["capacity"] == %{"shared_clean" => 3, "exclusive" => 1}
    assert body["freshness"] == "fresh"
    assert body["stale?"] == false
    assert body["version"] == Runs.min_runner_version()
    assert body["outdated"] == false
    assert body["jobs"] == []
    assert body["last_heartbeat"]
  end

  test "a runner below the minimum version is flagged outdated, independent of freshness", %{
    conn: conn,
    board: board
  } do
    insert(:runner, board: board, name: "old-timer", version: Runs.min_runner_version() - 1)

    [body] = conn |> get(~p"/api/runners") |> json_response(200) |> Map.fetch!("data")

    assert body["freshness"] == "fresh"
    assert body["outdated"] == true
  end

  test "a runner silent past the reclaim threshold is gone, and marked stale", %{conn: conn, board: board} do
    old = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -3600, :second)
    insert(:runner, board: board, name: "ghost", last_heartbeat: old)

    [body] = conn |> get(~p"/api/runners") |> json_response(200) |> Map.fetch!("data")

    assert body["freshness"] == "gone"
    assert body["stale?"] == true
  end

  test "a runner that has missed one beat but isn't reclaimable yet is merely stale", %{conn: conn, board: board} do
    # interval: 30 -> fresh through 45s, gone past 60s (max(60, 2 * 30)). 50s lands in the
    # untested middle: a missed beat, but the reaper has not touched its work yet.
    borderline = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -50, :second)
    insert(:runner, board: board, name: "flaky", interval: 30, last_heartbeat: borderline)

    [body] = conn |> get(~p"/api/runners") |> json_response(200) |> Map.fetch!("data")

    assert body["freshness"] == "stale"
    assert body["stale?"] == true
  end

  test "the jobs a runner holds are listed", %{conn: conn, board: board} do
    stage = insert(:stage, board: board, position: 1)
    card = insert(:card, stage: stage)
    run = insert(:run, card: card)
    execution = insert(:node_execution, run: run, node_key: "implement")
    insert(:node_job, node_execution: execution, state: :claimed, runner_name: "mac")
    insert(:runner, board: board, name: "mac")

    [body] = conn |> get(~p"/api/runners") |> json_response(200) |> Map.fetch!("data")

    assert [job] = body["jobs"]
    assert job["node_key"] == "implement"
    assert job["state"] == "claimed"
    assert job["ref"] == Cards.ref(board, card)
  end

  test "another board's runners never appear", %{conn: conn} do
    other = insert(:board, key: "OTH")
    insert(:runner, board: other, name: "theirs")

    assert conn |> get(~p"/api/runners") |> json_response(200) |> Map.fetch!("data") == []
  end

  test "RE320: a paused runner exposes its rate_limit and :rate_limited display state", %{conn: conn, board: board} do
    insert(:runner,
      board: board,
      name: "paused",
      version: Runs.min_runner_version(),
      rate_limit: build(:runner_rate_limit, resets_at: ~U[2100-01-01 00:00:00Z])
    )

    [body] = conn |> get(~p"/api/runners") |> json_response(200) |> Map.fetch!("data")

    assert body["display_state"] == "rate_limited"

    assert body["rate_limit"] == %{
             "window" => "five_hour",
             "utilization" => 0.95,
             "max" => 0.9,
             "resets_at" => "2100-01-01T00:00:00Z",
             "reason" => "limit"
           }
  end
end
