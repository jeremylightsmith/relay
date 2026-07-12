defmodule RelayWeb.Api.BoardControllerTest do
  use RelayWeb.ConnCase, async: true

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), board: board}
  end

  test "returns the key's board with stages and cards (status + owners)", %{conn: conn, board: board} do
    stage = insert(:stage, board: board, name: "Plan", type: :work, ai_enabled: true, position: 1)
    card = insert(:card, stage: stage, title: "Ship it", status: :working)
    insert(:card_owner, card: card)

    other = insert(:board)
    insert(:card, stage: insert(:stage, board: other))

    body = conn |> get(~p"/api/board") |> json_response(200)

    assert body["board"]["key"] == board.key
    assert Enum.any?(body["stages"], &(&1["name"] == "Plan" and &1["type"] == "work" and &1["ai_enabled"] == true))

    assert [card_json] = body["cards"]
    assert card_json["title"] == "Ship it"
    assert card_json["status"] == "working"
    assert card_json["active_owner"] == "ai"
    assert [%{"type" => "agent"}] = card_json["owners"]
  end

  test "stage JSON carries wip_limit, type, and parent_id for sub-lane WIP", %{conn: conn, board: board} do
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1, wip_limit: 3)
    _review = insert(:stage, board: board, name: "Code:Review", type: :review, position: 2, parent: code)

    body = conn |> get(~p"/api/board") |> json_response(200)

    main = Enum.find(body["stages"], &(&1["name"] == "Code"))
    assert main["wip_limit"] == 3
    assert main["type"] == "work"
    assert main["parent_id"] == nil

    sub = Enum.find(body["stages"], &(&1["name"] == "Code:Review"))
    assert sub["type"] == "review"
    assert sub["parent_id"] == code.id
    assert sub["wip_limit"] == nil
  end

  test "board card JSON omits heavy plan/spec text", %{conn: conn, board: board} do
    stage = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    insert(:card, stage: stage, title: "Heavy", plan: "big plan text", spec: "big spec text")

    [card_json] = conn |> get(~p"/api/board") |> json_response(200) |> Map.fetch!("cards")

    refute Map.has_key?(card_json, "plan")
    refute Map.has_key?(card_json, "spec")
  end

  describe "GET /api/board/version" do
    test "returns 200 with an integer version and a matching ETag header", %{conn: conn} do
      conn = get(conn, ~p"/api/board/version")

      assert %{"version" => version} = json_response(conn, 200)
      assert is_integer(version)
      assert [etag] = get_resp_header(conn, "etag")
      assert etag == Integer.to_string(version)
    end

    test "the version strictly increases after a board mutation", %{conn: conn, board: board} do
      before =
        conn |> get(~p"/api/board/version") |> json_response(200) |> Map.fetch!("version")

      stage = insert(:stage, board: board, name: "Plan", type: :work, ai_enabled: true, position: 1)
      {:ok, _card} = Relay.Cards.create_card(stage, %{title: "New card"})

      after_version =
        conn |> get(~p"/api/board/version") |> json_response(200) |> Map.fetch!("version")

      assert after_version > before
    end

    test "an unauthenticated request is rejected with 401" do
      conn = get(build_conn(), ~p"/api/board/version")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/board Done-column exclusion (RLY-67)" do
    setup %{board: board} do
      code = insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 1)
      done = insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 2)

      done_sub =
        insert(:stage, board: board, name: "Code:Done", type: :done, category: :complete, position: 3, parent: code)

      %{code: code, done: done, done_sub: done_sub}
    end

    test "excludes top-level Done cards by default, keeps in-progress and done sub-lane cards",
         %{conn: conn, code: code, done: done, done_sub: done_sub} do
      insert(:card, stage: code, title: "Working")
      insert(:card, stage: done, title: "Shipped")
      insert(:card, stage: done_sub, title: "Sub-done")

      titles = conn |> get(~p"/api/board") |> json_response(200) |> Map.fetch!("cards") |> Enum.map(& &1["title"])

      assert "Working" in titles
      assert "Sub-done" in titles
      refute "Shipped" in titles
    end

    test "includes top-level Done cards with ?include_done=1", %{conn: conn, done: done} do
      insert(:card, stage: done, title: "Shipped")

      titles =
        conn |> get(~p"/api/board?include_done=1") |> json_response(200) |> Map.fetch!("cards") |> Enum.map(& &1["title"])

      assert "Shipped" in titles
    end
  end

  test "board card JSON omits ai_result", %{conn: conn, board: board} do
    stage = insert(:stage, board: board, position: 1)
    insert(:card, stage: stage, ai_result: %{"summary" => "did it"})

    [card_json] = conn |> get(~p"/api/board") |> json_response(200) |> Map.fetch!("cards")
    refute Map.has_key?(card_json, "ai_result")
  end
end
