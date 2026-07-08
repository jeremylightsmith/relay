defmodule RelayWeb.Api.CardControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Activity
  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Spec", owner: :human, position: 1)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, stage: stage}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  test "GET /api/cards lists the board's cards", %{conn: conn, stage: stage} do
    insert(:card, stage: stage, title: "A")
    insert(:card, stage: stage, title: "B")

    titles = conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["title"])
    assert "A" in titles and "B" in titles
  end

  test "GET /api/cards/:ref returns the card with its timeline", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Read me", description: "details")
    {:ok, _} = Activity.add_comment(card, %{actor: :agent, body: "hello from AI"})

    body = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert body["title"] == "Read me"
    assert body["description"] == "details"
    assert Enum.any?(body["timeline"], &(&1["kind"] == "comment" and &1["author"]["name"] == "Relay AI"))
  end

  test "unknown ref and another board's ref both 404", %{conn: conn, board: board} do
    other_card = insert(:card, stage: insert(:stage, board: insert(:board)))

    assert conn |> get(~p"/api/cards/RLY-9999") |> json_response(404)
    assert conn |> get(~p"/api/cards/#{ref(board, other_card)}") |> json_response(404)
  end

  test "PATCH updates title and status", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Old")

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{title: "New", status: "in_review"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["title"] == "New"
    assert body["status"] == "in_review"
  end

  test "PATCH owners claims for AI then hands back to a user", %{conn: conn, board: board, stage: stage} do
    user = insert(:user)
    card = insert(:card, stage: stage)

    ai =
      conn |> patch(~p"/api/cards/#{ref(board, card)}", %{owners: ["agent"]}) |> json_response(200) |> Map.fetch!("data")

    assert ai["active_owner"] == "ai"

    human =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{owners: ["user:#{user.id}"]})
      |> json_response(200)
      |> Map.fetch!("data")

    assert human["active_owner"] == "human"
    assert [%{"type" => "user", "id" => id}] = human["owners"]
    assert id == user.id
  end

  test "PATCH invalid status returns 400", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)
    assert conn |> patch(~p"/api/cards/#{ref(board, card)}", %{status: "bogus"}) |> json_response(400)
  end

  test "PATCH malformed owners returns 400 instead of crashing", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    assert conn |> patch(~p"/api/cards/#{ref(board, card)}", %{owners: ["nonsense"]}) |> json_response(400)
    assert conn |> patch(~p"/api/cards/#{ref(board, card)}", %{owners: ["user:abc"]}) |> json_response(400)
    assert conn |> patch(~p"/api/cards/#{ref(board, card)}", %{owners: ["user:"]}) |> json_response(400)
  end
end
