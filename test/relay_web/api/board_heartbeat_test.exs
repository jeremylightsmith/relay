defmodule RelayWeb.Api.BoardHeartbeatTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards
  alias Relay.Repo

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
end
