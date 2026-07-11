defmodule RelayWeb.Api.CardGatesTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)

    code =
      insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, category: :in_progress, position: 1)

    review =
      insert(:stage,
        board: board,
        name: "Review",
        type: :review,
        ai_enabled: false,
        category: :in_progress,
        position: 2
      )

    deploy =
      insert(:stage, board: board, name: "Deploy", type: :work, ai_enabled: true, category: :in_progress, position: 3)

    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, code: code, review: review, deploy: deploy}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  defp in_review_card(stage) do
    card = insert(:card, stage: stage)
    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    card
  end

  test "POST approve advances the card, attributed to Relay AI", %{
    conn: conn,
    board: board,
    review: review,
    deploy: deploy
  } do
    card = in_review_card(review)

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

  test "POST reject with no :to routes the card to the previous main stage, note attached", %{
    conn: conn,
    board: board,
    review: review,
    code: code
  } do
    card = in_review_card(review)

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

  test "reject without a note 422s missing_note", %{conn: conn, board: board, review: review} do
    card = in_review_card(review)

    body = conn |> post(~p"/api/cards/#{ref(board, card)}/reject", %{}) |> json_response(422)
    assert body["error"]["code"] == "missing_note"
  end

  test "approve and reject on a non-review stage 422 not_in_review", %{conn: conn, board: board, code: code} do
    card = insert(:card, stage: code)

    approve_body = conn |> post(~p"/api/cards/#{ref(board, card)}/approve") |> json_response(422)
    assert approve_body["error"]["code"] == "not_in_review"

    reject_body = conn |> post(~p"/api/cards/#{ref(board, card)}/reject", %{note: "no"}) |> json_response(422)
    assert reject_body["error"]["code"] == "not_in_review"
  end

  test "approve and reject on an unknown ref 404", %{conn: conn} do
    assert conn |> post(~p"/api/cards/RLY-9999/approve") |> json_response(404)
    assert conn |> post(~p"/api/cards/RLY-9999/reject", %{note: "x"}) |> json_response(404)
  end

  test "GET card exposes the open rejection top-level (not in timeline), nil when clean", %{
    conn: conn,
    board: board,
    review: review,
    code: code
  } do
    card = in_review_card(review)

    clean = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert clean["rejection"] == nil

    {:ok, _rejected} = Cards.reject(card, "Handle the empty case", :agent)

    data = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert data["rejection"]["note"] == "Handle the empty case"
    assert data["rejection"]["to_stage"] == "Code"
    assert data["rejection"]["from_stage"] == "Review"
    assert data["rejection"]["rejected_by"] == "Relay AI"
    # It is NOT just another timeline comment/activity of its own kind.
    refute Enum.any?(data["timeline"], &(&1["kind"] == "rejection"))
    assert code.id == data["stage_id"]
  end

  test "POST reject with an explicit :to sends the card there", %{
    conn: conn,
    board: board,
    review: review,
    code: code
  } do
    card = in_review_card(review)

    data =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/reject", %{note: "spec problem", to: "Code"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["stage_id"] == code.id
    assert data["rejection"]["to_stage"] == "Code"
  end

  test "POST reject with an explicit :to works on a NON-review card (universal send-back)", %{
    conn: conn,
    board: board,
    code: code,
    deploy: deploy
  } do
    # Deploy (position 3) is not review-type; a target still makes it a valid send-back.
    card = insert(:card, stage: deploy)

    data =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/reject", %{note: "back to code", to: code.id})
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["stage_id"] == code.id
    assert data["rejection"]["to_stage"] == "Code"
  end

  test "POST reject with a forward/unknown :to 422s invalid_target", %{
    conn: conn,
    board: board,
    review: review,
    deploy: deploy
  } do
    card = in_review_card(review)

    forward = conn |> post(~p"/api/cards/#{ref(board, card)}/reject", %{note: "x", to: deploy.id}) |> json_response(422)
    assert forward["error"]["code"] == "invalid_target"

    unknown =
      conn |> post(~p"/api/cards/#{ref(board, card)}/reject", %{note: "x", to: "Nonexistent"}) |> json_response(422)

    assert unknown["error"]["code"] == "invalid_target"
  end

  test "GET /api/board stage payloads carry type/ai_enabled, not owner/lane/approval_gate/reject_to_stage_id", %{
    conn: conn,
    review: review
  } do
    stages = conn |> get(~p"/api/board") |> json_response(200) |> Map.fetch!("stages")
    payload = Enum.find(stages, &(&1["id"] == review.id))

    assert payload["type"] == "review"
    assert Map.has_key?(payload, "ai_enabled")
    refute Map.has_key?(payload, "owner")
    refute Map.has_key?(payload, "approval_gate")
    refute Map.has_key?(payload, "lane")
    refute Map.has_key?(payload, "reject_to_stage_id")
  end
end
