defmodule RelayWeb.Api.DiagnosisControllerTest do
  use RelayWeb.ConnCase, async: false

  alias Relay.Cards

  setup %{conn: conn} do
    Relay.Runs.Capacity.reset()
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    queue = insert(:stage, board: board, name: "Plan:Done", position: 1, type: :queue)
    works = insert(:stage, board: board, name: "Code", position: 2, type: :work)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, queue: queue, works: works}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  test "a card no flow pulls from diagnoses as no_enabled_flow", %{conn: conn, board: board, queue: queue} do
    card = insert(:card, stage: queue, status: :ready)

    body = conn |> get(~p"/api/cards/#{ref(board, card)}/diagnosis") |> json_response(200) |> Map.fetch!("data")

    assert body["verdict"] == "no_enabled_flow"
    assert body["detail"] =~ "no enabled flow"
    assert body["evidence"]["flow_key"] == nil
  end

  test "an enabled flow with nothing connected diagnoses as awaiting_capacity", %{
    conn: conn,
    board: board,
    queue: queue,
    works: works
  } do
    insert(:flow, board: board, key: "code", enabled: true, pulls_from_stage_id: queue.id, works_in_stage_id: works.id)
    card = insert(:card, stage: queue, status: :ready)

    body = conn |> get(~p"/api/cards/#{ref(board, card)}/diagnosis") |> json_response(200) |> Map.fetch!("data")

    assert body["verdict"] == "awaiting_capacity"
    assert body["evidence"]["flow_key"] == "code"
  end

  test "an unknown ref is 404", %{conn: conn} do
    assert conn |> get(~p"/api/cards/RLY-9999/diagnosis") |> json_response(404)
  end

  test "another board's card is 404, never 403 and never data", %{conn: conn, queue: queue} do
    other_board = insert(:board, key: "OTH")
    other_stage = insert(:stage, board: other_board, name: "Plan:Done", position: 1)
    other_card = insert(:card, stage: other_stage)
    _mine = insert(:card, stage: queue)

    assert conn |> get(~p"/api/cards/#{Cards.ref(other_board, other_card)}/diagnosis") |> json_response(404)
  end
end
