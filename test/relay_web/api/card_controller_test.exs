defmodule RelayWeb.Api.CardControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Activity
  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Spec", position: 1)
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

  test "GET /api/cards list omits plan and spec", %{conn: conn, stage: stage} do
    insert(:card, stage: stage, plan: "p", spec: "s")

    [card_json] = conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data")

    refute Map.has_key?(card_json, "plan")
    refute Map.has_key?(card_json, "spec")
  end

  test "GET /api/cards/:ref detail still returns plan and spec", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, plan: "the plan", spec: "the spec")

    body = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")

    assert body["plan"] == "the plan"
    assert body["spec"] == "the spec"
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

  test "PATCH updates title and status", %{conn: conn, board: board} do
    review = insert(:stage, board: board, type: :review, position: 2)
    card = insert(:card, stage: review, status: :in_review, title: "Old")

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{title: "New", status: "in_review"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["title"] == "New"
    assert body["status"] == "in_review"
  end

  test "PATCH status ready on a review-stage card is coerced to in_review", %{conn: conn, board: board} do
    review = insert(:stage, board: board, type: :review, position: 3)
    card = insert(:card, stage: review, status: :in_review)

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{status: "ready"})
      |> json_response(200)
      |> Map.fetch!("data")

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

  test "PATCH sets branch and plan and GET /api/cards/:ref returns them",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Runner card")

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{
        branch: "rly-21-card-branch-plan",
        plan: "## Task 1\n\nDo the thing"
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["branch"] == "rly-21-card-branch-plan"
    assert body["plan"] == "## Task 1\n\nDo the thing"

    fetched = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert fetched["branch"] == "rly-21-card-branch-plan"
    assert fetched["plan"] == "## Task 1\n\nDo the thing"
  end

  test "GET /api/board card JSON includes branch but omits plan", %{conn: conn, stage: stage} do
    card = insert(:card, stage: stage, title: "Runner card")
    {:ok, _card} = Cards.update_card(card, %{branch: "rly-21-b", plan: "the plan"})

    body = conn |> get(~p"/api/board") |> json_response(200)

    assert [card_json] = body["cards"]
    assert card_json["branch"] == "rly-21-b"
    refute Map.has_key?(card_json, "plan")
  end

  test "PATCH sets pr_url and GET /api/cards/:ref returns it",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Runner card")

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{
        pr_url: "https://github.com/acme/relay/pull/42"
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["pr_url"] == "https://github.com/acme/relay/pull/42"

    fetched = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert fetched["pr_url"] == "https://github.com/acme/relay/pull/42"
  end

  test "GET /api/board card JSON includes pr_url", %{conn: conn, stage: stage} do
    card = insert(:card, stage: stage, title: "Runner card")
    {:ok, _card} = Cards.update_card(card, %{pr_url: "https://github.com/acme/relay/pull/42"})

    body = conn |> get(~p"/api/board") |> json_response(200)

    assert [card_json] = body["cards"]
    assert card_json["pr_url"] == "https://github.com/acme/relay/pull/42"
  end

  test "PATCH sets spec and GET /api/cards/:ref returns it",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Spec card")

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{spec: "## Design\n\nThe spec body"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["spec"] == "## Design\n\nThe spec body"

    fetched = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert fetched["spec"] == "## Design\n\nThe spec body"
  end

  test "GET /api/cards index omits spec", %{conn: conn, stage: stage} do
    card = insert(:card, stage: stage, title: "Spec card")
    {:ok, _card} = Cards.update_card(card, %{spec: "the spec"})

    [card_json] = conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data")
    refute Map.has_key?(card_json, "spec")
  end

  describe "POST /api/cards" do
    test "creates a ready, unowned card in the board's first stage with title only",
         %{conn: conn, stage: stage} do
      body =
        conn
        |> post(~p"/api/cards", %{title: "New card"})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["title"] == "New card"
      assert body["status"] == "ready"
      assert body["stage_id"] == stage.id
      assert body["owners"] == []
      assert body["active_owner"] == nil
      assert is_binary(body["ref"])
      # standard show shape includes description + timeline
      assert Map.has_key?(body, "description")
      assert is_list(body["timeline"])
    end

    test "creates a card into an explicit stage id", %{conn: conn, board: board} do
      other = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 2)

      body =
        conn
        |> post(~p"/api/cards", %{title: "Into code", stage: other.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["stage_id"] == other.id
    end

    test "accepts an integer-string stage id", %{conn: conn, board: board} do
      other = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 2)

      body =
        conn
        |> post(~p"/api/cards", %{title: "Into code", stage: to_string(other.id)})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["stage_id"] == other.id
    end

    test "created card appears in GET /api/cards", %{conn: conn} do
      conn |> post(~p"/api/cards", %{title: "Findable"}) |> json_response(201)

      titles =
        conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["title"])

      assert "Findable" in titles
    end

    test "records a :created timeline entry attributed to the agent", %{conn: conn} do
      body = conn |> post(~p"/api/cards", %{title: "Logged"}) |> json_response(201) |> Map.fetch!("data")

      assert Enum.any?(body["timeline"], fn e ->
               e["kind"] == "activity" and e["type"] == "created" and e["author"]["name"] == "Relay AI"
             end)
    end

    test "missing title returns 400", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{}) |> json_response(400)
    end

    test "blank title returns 400", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "   "}) |> json_response(400)
    end

    test "unknown stage id returns 404", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "x", stage: 999_999}) |> json_response(404)
    end

    test "uncastable stage id returns 404", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "x", stage: "not-a-number"}) |> json_response(404)
    end

    test "unauthenticated POST /api/cards returns 401" do
      build_conn() |> post(~p"/api/cards", %{title: "x"}) |> json_response(401)
    end
  end

  test "card payload carries the new status vocab plus done and needs_you",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, board: board, stage: stage, status: :ready)

    resp = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200)
    assert resp["data"]["status"] == "ready"
    assert resp["data"]["done"] == true
    assert resp["data"]["needs_you"] == false
  end

  test "board payload carries the needs_you rollup", %{conn: conn, board: board} do
    review = insert(:stage, board: board, name: "Review", type: :review, position: 2)
    insert(:card, board: board, stage: review, status: :in_review)

    resp = conn |> get(~p"/api/board") |> json_response(200)
    assert resp["needs_you"] == %{"needs_input" => 0, "in_review" => 1, "awaiting_human" => 0}
  end

  describe "GET /api/cards Done-column exclusion (RLY-67)" do
    test "excludes top-level Done cards by default, present with ?include_done=1",
         %{conn: conn, board: board} do
      done = insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 9)
      insert(:card, stage: done, title: "Shipped")

      default_titles = conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["title"])
      refute "Shipped" in default_titles

      included_titles =
        conn |> get(~p"/api/cards?include_done=1") |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["title"])

      assert "Shipped" in included_titles
    end
  end

  test "GET /api/cards list omits ai_result", %{conn: conn, stage: stage} do
    insert(:card, stage: stage, ai_result: %{"summary" => "x"})
    [card_json] = conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data")
    refute Map.has_key?(card_json, "ai_result")
  end

  test "GET /api/cards/:ref detail includes ai_result", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, ai_result: %{"summary" => "done"})
    body = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert body["ai_result"] == %{"summary" => "done"}
  end
end
