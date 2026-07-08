defmodule RelayWeb.Api.BoardControllerTest do
  use RelayWeb.ConnCase, async: true

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), board: board}
  end

  test "returns the key's board with stages and cards (status + owners)", %{conn: conn, board: board} do
    stage = insert(:stage, board: board, name: "Plan", owner: :ai, position: 1)
    card = insert(:card, stage: stage, title: "Ship it", status: :working, progress: 40)
    insert(:card_owner, card: card)

    other = insert(:board)
    insert(:card, stage: insert(:stage, board: other))

    body = conn |> get(~p"/api/board") |> json_response(200)

    assert body["board"]["key"] == board.key
    assert Enum.any?(body["stages"], &(&1["name"] == "Plan" and &1["owner"] == "ai"))

    assert [card_json] = body["cards"]
    assert card_json["title"] == "Ship it"
    assert card_json["status"] == "working"
    assert card_json["active_owner"] == "ai"
    assert [%{"type" => "agent"}] = card_json["owners"]
  end
end
