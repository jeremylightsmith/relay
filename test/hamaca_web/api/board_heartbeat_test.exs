defmodule HamacaWeb.Api.BoardHeartbeatTest do
  use HamacaWeb.ConnCase, async: true

  alias Hamaca.Cards
  alias Hamaca.Repo
  alias Hamaca.Runs.Capacity

  setup %{conn: conn} do
    board = insert(:board)
    stage = insert(:stage, board: board)
    {:ok, %{token: token}} = Hamaca.ApiKeys.create_key(board, board.owner)
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

    assert %{"stamped" => 1} = json_response(beat(conn, ["RL7"]), 200)

    assert Repo.get!(Schemas.Card, beaten.id).agent_heartbeat_at
    assert Repo.get!(Schemas.Card, untouched.id).agent_heartbeat_at == nil
  end

  test "cannot touch a card on another board", %{conn: conn} do
    other_board = insert(:board)
    other_card = insert(:card, stage: insert(:stage, board: other_board), ref_number: 7)

    assert %{"stamped" => 0} = json_response(beat(conn, ["RL7"]), 200)
    assert Repo.get!(Schemas.Card, other_card.id).agent_heartbeat_at == nil
  end

  test "an unknown or malformed ref is ignored, not an error", %{conn: conn} do
    assert %{"stamped" => 0} = json_response(beat(conn, ["RL9999", "nonsense", ""]), 200)
  end

  test "an empty ref list is a no-op", %{conn: conn} do
    assert %{"stamped" => 0} = json_response(beat(conn, []), 200)
  end

  test "touch_heartbeats/2 stamps a fresh timestamp", %{board: board, stage: stage} do
    card = insert(:card, stage: stage, ref_number: 3)
    before = DateTime.add(DateTime.utc_now(), -1, :second)

    assert {1, nil} = Cards.touch_heartbeats(board, ["RL3"])

    stamped = Repo.get!(Schemas.Card, card.id).agent_heartbeat_at
    assert DateTime.after?(stamped, before)
  end

  # RE496: a stalled agent's next heartbeat resolves the stall, so the badge drops — one silent
  # badge-only push per beat that revived a :stale card. A live → live beat sends nothing.
  describe "stall resolves (RE496)" do
    setup %{board: board} do
      member = insert(:user)
      insert(:membership, board: board, user: member)
      {:ok, _} = Hamaca.Push.register_device(member, "tok-m")
      %{ai_stage: insert_ai_stage(board: board)}
    end

    defp ago(seconds), do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

    defp agent_card(stage, ref_number, heartbeat_at) do
      card = insert(:card, stage: stage, status: :working, ref_number: ref_number, agent_heartbeat_at: heartbeat_at)
      insert(:card_owner, card: card)
      card
    end

    defp stale_card(stage, ref_number) do
      card = agent_card(stage, ref_number, ago(180))
      insert(:activity, card: card, type: :action, text: "reindexing", inserted_at: ago(180))
      card
    end

    test "a live card's beats push nothing", %{conn: conn, ai_stage: ai_stage} do
      agent_card(ai_stage, 3, ago(0))

      for _ <- 1..3 do
        assert %{"stamped" => 1} = json_response(beat(conn, ["RL3"]), 200)
      end

      refute_received {:push_delivered, _, _}
    end

    test "the beat that revives a stale card pushes the badge once", %{conn: conn, ai_stage: ai_stage} do
      stale_card(ai_stage, 3)

      assert %{"stamped" => 1} = json_response(beat(conn, ["RL3"]), 200)
      assert_received {:push_delivered, "tok-m", payload}
      assert payload == %{"aps" => %{"badge" => 0}}
      refute_received {:push_delivered, _, _}

      assert %{"stamped" => 1} = json_response(beat(conn, ["RL3"]), 200)
      refute_received {:push_delivered, _, _}
    end

    test "one beat reviving two stale cards pushes once", %{conn: conn, ai_stage: ai_stage} do
      stale_card(ai_stage, 3)
      stale_card(ai_stage, 4)

      assert %{"stamped" => 2} = json_response(beat(conn, ["RL3", "RL4"]), 200)
      assert_received {:push_delivered, "tok-m", payload}
      assert payload == %{"aps" => %{"badge" => 0}}
      refute_received {:push_delivered, _, _}
    end

    test "a stopped card is not resolved by a heartbeat", %{board: board, ai_stage: ai_stage} do
      card = agent_card(ai_stage, 3, ago(180))
      insert(:activity, card: card, type: :failure, text: "agent stopped", inserted_at: ago(180))

      assert {1, nil} = Cards.touch_heartbeats(board, ["RL3"])
      refute_received {:push_delivered, _, _}
    end
  end

  test "an unauthenticated POST is rejected with 401" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/board/heartbeat", Jason.encode!(%{"refs" => ["RL1"]}))

    assert json_response(conn, 401)
  end

  test "a legacy refs-only payload stamps cards", %{conn: conn, stage: stage} do
    insert(:card, stage: stage, ref_number: 7)

    assert %{"stamped" => 1} = json_response(beat(conn, ["RL7"]), 200)
  end

  test "a runner beat (name + capacity) upserts a Runner row",
       %{conn: conn, board: board, stage: stage} do
    insert(:card, stage: stage, ref_number: 7)

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
          "refs" => ["RL7"],
          "capacity" => %{"shared_clean" => 3, "exclusive" => 1}
        })
      )

    assert %{"stamped" => 1} = json_response(conn, 200)
    runner = Repo.get_by!(Schemas.Runner, board_id: board.id, name: "jeremy-mbp")
    assert runner.capacity == %{"shared_clean" => 3, "exclusive" => 1}
  end

  test "a capacity-less RLY-141 beat upserts no Runner row (additive, never subtractive)",
       %{conn: conn, board: _board, stage: stage} do
    insert(:card, stage: stage, ref_number: 7)

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/board/heartbeat", Jason.encode!(%{"runner_id" => "w1", "interval" => 30, "refs" => ["RL7"]}))
    |> json_response(200)

    assert Repo.aggregate(Schemas.Runner, :count) == 0
  end

  test "a runner beat carrying name + capacity lands free slots in Hamaca.Runs.Capacity",
       %{conn: conn, board: board} do
    {:ok, %{id: exec_id}} =
      Hamaca.Runs.upsert_runner(board, %{"name" => "exec-hb", "capacity" => %{"shared_clean" => 2}})

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

  test "a runner beat with an unknown class and a garbage value degrades, never 500s",
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

    runner = Repo.get_by!(Schemas.Runner, board_id: board.id, name: "exec-junk")
    assert runner.capacity == %{"shared_clean" => 0, "exclusive" => 2}
    assert Capacity.snapshot()[runner.id] == %{shared_clean: 0, exclusive: 2}
  end
end
