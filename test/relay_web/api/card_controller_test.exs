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

  describe "POST /api/cards" do
    test "creates a card with title only, landing in the board's first stage", %{conn: conn, board: board} do
      first = insert(:stage, board: board, name: "Backlog", owner: :human, position: 0)

      body =
        conn
        |> post(~p"/api/cards", %{title: "New card"})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["title"] == "New card"
      assert body["status"] == "queued"
      assert body["stage_id"] == first.id
      assert body["owners"] == []
      assert Enum.any?(body["timeline"], &(&1["type"] == "created" and &1["author"]["name"] == "Relay AI"))
    end

    test "creates a card into an explicit stage id", %{conn: conn, stage: stage} do
      body =
        conn
        |> post(~p"/api/cards", %{title: "Placed", stage: stage.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["stage_id"] == stage.id
    end

    test "accepts a stage id given as a string", %{conn: conn, stage: stage} do
      body =
        conn
        |> post(~p"/api/cards", %{title: "Placed", stage: to_string(stage.id)})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["stage_id"] == stage.id
    end

    test "400 when title is missing", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{}) |> json_response(400)
    end

    test "400 when title is blank", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "   "}) |> json_response(400)
    end

    test "404 when the stage id is unknown", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "X", stage: 999_999}) |> json_response(404)
    end

    test "404 when the stage id is uncastable", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "X", stage: "not-an-int"}) |> json_response(404)
    end

    test "created card appears in GET /api/cards", %{conn: conn} do
      conn |> post(~p"/api/cards", %{title: "Findable"}) |> json_response(201)

      titles =
        conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["title"])

      assert "Findable" in titles
    end

    test "unauthenticated POST /api/cards is rejected", %{board: board} do
      insert(:stage, board: board, name: "Backlog", owner: :human, position: 0)

      assert build_conn() |> post(~p"/api/cards", %{title: "Nope"}) |> json_response(401)
    end
  end
end
