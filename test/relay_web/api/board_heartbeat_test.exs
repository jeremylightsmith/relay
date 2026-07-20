defmodule RelayWeb.Api.BoardHeartbeatTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards
  alias Relay.Repo
  alias Relay.RunnerPresence
  alias Relay.Runs.Capacity

  setup %{conn: conn} do
    board = insert(:board)
    stage = insert(:stage, board: board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), board: board, stage: stage}
  end

  defp beat(conn, refs) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/board/heartbeat", Jason.encode!(%{"refs" => refs}))
  end

  test "stamps only the named refs", %{conn: conn, stage: stage} do
    beaten = insert(:card, stage: stage, ref_number: 7)
    untouched = insert(:card, stage: stage, ref_number: 9)

    assert %{"stamped" => 1} = json_response(beat(conn, ["RLY-7"]), 200)

    assert Repo.get!(Schemas.Card, beaten.id).agent_heartbeat_at
    assert Repo.get!(Schemas.Card, untouched.id).agent_heartbeat_at == nil
  end

  test "cannot touch a card on another board", %{conn: conn} do
    other_board = insert(:board)
    other_card = insert(:card, stage: insert(:stage, board: other_board), ref_number: 7)

    assert %{"stamped" => 0} = json_response(beat(conn, ["RLY-7"]), 200)
    assert Repo.get!(Schemas.Card, other_card.id).agent_heartbeat_at == nil
  end

  test "an unknown or malformed ref is ignored, not an error", %{conn: conn} do
    assert %{"stamped" => 0} = json_response(beat(conn, ["RLY-9999", "nonsense", ""]), 200)
  end

  test "an empty ref list is a no-op", %{conn: conn} do
    assert %{"stamped" => 0} = json_response(beat(conn, []), 200)
  end

  test "touch_heartbeats/2 stamps a fresh timestamp", %{board: board, stage: stage} do
    card = insert(:card, stage: stage, ref_number: 3)
    before = DateTime.add(DateTime.utc_now(), -1, :second)

    assert {1, nil} = Cards.touch_heartbeats(board, ["RLY-3"])

    stamped = Repo.get!(Schemas.Card, card.id).agent_heartbeat_at
    assert DateTime.after?(stamped, before)
  end

  test "an unauthenticated POST is rejected with 401" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/board/heartbeat", Jason.encode!(%{"refs" => ["RLY-1"]}))

    assert json_response(conn, 401)
  end

  test "a runner_id payload registers presence with pools and jobs, and still stamps cards",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, ref_number: 7)
    :ok = RunnerPresence.subscribe(board.id)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/board/heartbeat",
        Jason.encode!(%{
          "runner_id" => "mbp-1-aaaa",
          "host" => "mbp",
          "started_at" => "2026-07-17T08:00:00Z",
          "interval" => 30,
          "pools" => [%{"name" => "clean", "mode" => "shared", "used" => 1, "total" => 3}],
          "jobs" => [%{"ref" => "RLY-7", "stage" => "Code", "pool" => "clean", "started_at" => "2026-07-17T08:01:00Z"}],
          "refs" => ["RLY-7"]
        })
      )

    assert %{"stamped" => 1} = json_response(conn, 200)
    assert Repo.get!(Schemas.Card, card.id).agent_heartbeat_at

    assert_receive {:runner_beat, runner}
    assert runner.runner_id == "mbp-1-aaaa"
    assert [%{name: "clean", used: 1, total: 3}] = runner.pools
    assert [%{ref: "RLY-7", stage: "Code"}] = runner.jobs
  end

  test "a legacy refs-only payload stamps cards and registers nothing",
       %{conn: conn, board: board, stage: stage} do
    insert(:card, stage: stage, ref_number: 7)

    assert %{"stamped" => 1} = json_response(beat(conn, ["RLY-7"]), 200)
    assert RunnerPresence.list(board.id) == []
  end

  test "an executor beat (name + capacity) upserts an Executor row AND still feeds presence",
       %{conn: conn, board: board, stage: stage} do
    insert(:card, stage: stage, ref_number: 7)
    :ok = RunnerPresence.subscribe(board.id)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/board/heartbeat",
        Jason.encode!(%{
          "runner_id" => "mbp-1",
          "name" => "jeremy-mbp",
          "host" => "mbp",
          "interval" => 30,
          "pools" => [%{"name" => "clean", "mode" => "shared", "used" => 0, "total" => 3}],
          "jobs" => [],
          "refs" => ["RLY-7"],
          "capacity" => %{"shared_clean" => 3, "exclusive" => 1}
        })
      )

    assert %{"stamped" => 1} = json_response(conn, 200)
    # Still appears in the existing Runners view (RLY-141) — zero UI change.
    assert_receive {:runner_beat, %{runner_id: "mbp-1"}}
    # And now upserts the durable executor row.
    executor = Repo.get_by!(Schemas.Executor, board_id: board.id, name: "jeremy-mbp")
    assert executor.capacity == %{"shared_clean" => 3, "exclusive" => 1}
  end

  test "a capacity-less RLY-141 beat upserts no Executor row (additive, never subtractive)",
       %{conn: conn, board: _board, stage: stage} do
    insert(:card, stage: stage, ref_number: 7)

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/board/heartbeat", Jason.encode!(%{"runner_id" => "w1", "interval" => 30, "refs" => ["RLY-7"]}))
    |> json_response(200)

    assert Repo.aggregate(Schemas.Executor, :count) == 0
  end

  test "an executor beat carrying name + capacity lands free slots in Relay.Runs.Capacity",
       %{conn: conn, board: board} do
    {:ok, %{id: exec_id}} =
      Relay.Runs.upsert_executor(board, %{"name" => "exec-hb", "capacity" => %{"shared_clean" => 2}})

    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      ~p"/api/board/heartbeat",
      Jason.encode!(%{
        "name" => "exec-hb",
        "host" => "dev",
        "interval" => 30,
        "capacity" => %{"shared_clean" => 2, "exclusive" => 0}
      })
    )
    |> json_response(200)

    assert %{shared_clean: 2, exclusive: 0} = Map.get(Capacity.snapshot(), exec_id)
  end

  test "an executor beat with an unknown class and a garbage value degrades, never 500s",
       %{conn: conn, board: board} do
    # RLY-201: both heartbeat routes must shape capacity the same way — one normalizer.
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      ~p"/api/board/heartbeat",
      Jason.encode!(%{
        "name" => "exec-junk",
        "host" => "dev",
        "interval" => 30,
        "capacity" => %{"gpu" => 1, "shared_clean" => "lots", "exclusive" => 2}
      })
    )
    |> json_response(200)

    executor = Repo.get_by!(Schemas.Executor, board_id: board.id, name: "exec-junk")
    assert executor.capacity == %{"shared_clean" => 0, "exclusive" => 2}
    assert Capacity.snapshot()[executor.id] == %{shared_clean: 0, exclusive: 2}
  end
end
