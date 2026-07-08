defmodule RelayWeb.Api.CardGatesTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Boards
  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    code = insert(:stage, board: board, name: "Code", owner: :ai, category: :in_progress, position: 1)

    review =
      insert(:stage,
        board: board,
        name: "Review",
        owner: :human,
        category: :in_progress,
        position: 2,
        approval_gate: true
      )

    deploy = insert(:stage, board: board, name: "Deploy", owner: :ai, category: :in_progress, position: 3)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, code: code, review: review, deploy: deploy}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  test "POST approve advances the card, attributed to Relay AI", %{
    conn: conn,
    board: board,
    review: review,
    deploy: deploy
  } do
    card = insert(:card, stage: review)

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/approve")
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["stage_id"] == deploy.id
    assert body["status"] == "working"

    approved = Enum.find(body["timeline"], &(&1["kind"] == "activity" and &1["type"] == "approved"))
    assert approved["author"]["name"] == "Relay AI"
    assert approved["meta"] == %{"from_stage" => "Review", "to_stage" => "Deploy"}
  end

  test "POST reject routes the card with the note attached", %{
    conn: conn,
    board: board,
    review: review,
    code: code
  } do
    {:ok, _stage} = Boards.update_stage(review, %{reject_to_stage_id: code.id})
    card = insert(:card, stage: review)

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/reject", %{note: "Handle the empty case"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["stage_id"] == code.id
    assert body["status"] == "working"
    assert Enum.any?(body["timeline"], &(&1["kind"] == "comment" and &1["body"] == "Handle the empty case"))

    rejected = Enum.find(body["timeline"], &(&1["kind"] == "activity" and &1["type"] == "rejected"))
    assert rejected["author"]["name"] == "Relay AI"
    assert rejected["meta"]["note"] == "Handle the empty case"
  end

  test "reject without a note 422s", %{conn: conn, board: board, review: review} do
    card = insert(:card, stage: review)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/reject", %{}) |> json_response(422)
  end

  test "approve and reject on a non-gated stage 422", %{conn: conn, board: board, code: code} do
    card = insert(:card, stage: code)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/approve") |> json_response(422)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/reject", %{note: "no"}) |> json_response(422)
  end

  test "approve and reject on an unknown ref 404", %{conn: conn} do
    assert conn |> post(~p"/api/cards/RLY-9999/approve") |> json_response(404)
    assert conn |> post(~p"/api/cards/RLY-9999/reject", %{note: "x"}) |> json_response(404)
  end

  test "GET /api/board stage payloads include the gate fields", %{conn: conn, review: review, code: code} do
    {:ok, _stage} = Boards.update_stage(review, %{reject_to_stage_id: code.id})

    stages = conn |> get(~p"/api/board") |> json_response(200) |> Map.fetch!("stages")
    payload = Enum.find(stages, &(&1["id"] == review.id))

    assert payload["approval_gate"] == true
    assert payload["reject_to_stage_id"] == code.id
  end
end
