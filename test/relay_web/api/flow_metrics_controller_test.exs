defmodule RelayWeb.Api.FlowMetricsControllerTest do
  use RelayWeb.ConnCase, async: true

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board}
  end

  test "returns summary + nodes with cost null when blank", %{conn: conn, board: board} do
    insert(:flow, board: board, key: "code", nodes: [%Schemas.Flow.Node{key: "implement", type: :agent, model: "sonnet"}])
    card = insert(:card, board: board, stage: insert(:stage, board: board))
    run = insert(:run, card: card, flow_key: "code", status: :done)
    insert(:node_execution, run: run, node: "implement", duration_s: 60, cost: nil)

    body = conn |> get(~p"/api/flows/code/metrics") |> json_response(200) |> Map.fetch!("data")

    assert %{"total_runs" => 1, "completed" => 1} = body["summary"]
    assert [node] = body["nodes"]
    assert node["node_key"] == "implement"
    assert node["runs"] == 1
    assert node["cost_p50"] == nil
    assert node["cost_p95"] == nil
    assert is_map(node["verdict_split"])
    assert Map.has_key?(node, "loop_laps")
  end

  test "honors the window param", %{conn: conn, board: board} do
    insert(:flow, board: board, key: "code", nodes: [%Schemas.Flow.Node{key: "implement", type: :agent}])
    body = conn |> get(~p"/api/flows/code/metrics?window=7d") |> json_response(200) |> Map.fetch!("data")
    assert body["nodes"] == []
  end

  test "404s an unknown flow key", %{conn: conn} do
    assert conn |> get(~p"/api/flows/nope/metrics") |> json_response(404)
  end

  describe "?card= scoping (RE235)" do
    setup %{board: board} do
      flow =
        insert(:flow,
          board: board,
          key: "code",
          nodes: [%Schemas.Flow.Node{key: "implement", type: :agent, model: "sonnet"}]
        )

      stage = insert(:stage, board: board)
      card = insert(:card, board: board, stage: stage)
      other = insert(:card, board: board, stage: stage)

      started = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -600, :second)

      run =
        insert(:run,
          card: card,
          flow_key: "code",
          status: :done,
          started_at: started,
          finished_at: DateTime.add(started, 600, :second)
        )

      insert(:node_execution, run: run, node: "implement", duration_s: 30, cost: Decimal.new("0.50"))
      insert(:node_execution, run: run, node: "implement", duration_s: 90, cost: Decimal.new("1.00"))

      other_run = insert(:run, card: other, flow_key: "code", status: :done)
      insert(:node_execution, run: other_run, node: "implement", duration_s: 1000, cost: Decimal.new("9.00"))

      {:ok, flow: flow, ref: Relay.Cards.ref(board, card)}
    end

    test "scopes every figure to the card and nulls the percentiles", %{conn: conn, ref: ref} do
      body =
        conn
        |> get(~p"/api/flows/code/metrics?#{[card: ref]}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert body["scope"] == "card"
      assert body["card"] == ref

      assert [node] = body["nodes"]
      assert node["runs"] == 2
      assert node["duration_total"] == 120
      assert node["cost_total"] == "1.50"
      assert node["duration_p50"] == nil
      assert node["duration_p95"] == nil
      assert node["cost_p50"] == nil
      assert node["cost_p95"] == nil

      assert body["summary"]["total_runs"] == 1
      assert body["summary"]["total_end_to_end"] == 600
      assert body["summary"]["median_end_to_end"] == nil
      assert body["summary"]["total_spend"] == "1.50"
    end

    test "?card= ignores ?window= — all of the card's runs count (decision 3)", %{conn: conn, ref: ref} do
      body =
        conn
        |> get(~p"/api/flows/code/metrics?#{[card: ref, window: "7d"]}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert [%{"runs" => 2}] = body["nodes"]
    end

    test "404s an unknown, unparseable or other-board card ref", %{conn: conn, board: board} do
      other_board = insert(:board, key: board.key)
      other_card = insert(:card, board: other_board, stage: insert(:stage, board: other_board))
      other_ref = Relay.Cards.ref(other_board, other_card)

      assert conn |> get(~p"/api/flows/code/metrics?#{[card: "ZZ999"]}") |> json_response(404)
      assert conn |> get(~p"/api/flows/code/metrics?#{[card: "nonsense"]}") |> json_response(404)
      assert conn |> get(~p"/api/flows/code/metrics?#{[card: other_ref]}") |> json_response(404)
    end

    test "without ?card= the response keeps today's keys and values, plus the additive ones", %{conn: conn} do
      body = conn |> get(~p"/api/flows/code/metrics") |> json_response(200) |> Map.fetch!("data")

      assert body["scope"] == "flow"
      assert body["card"] == nil

      assert [node] = body["nodes"]
      # 3 executions across both cards: 30 / 90 / 1000 -> p50 is the middle value
      assert node["runs"] == 3
      assert node["duration_p50"] == 90
      assert node["cost_p50"] == "1.00"
      assert node["duration_total"] == 1120
      assert node["cost_total"] == "10.50"
      assert body["summary"]["median_end_to_end"]
    end
  end
end
