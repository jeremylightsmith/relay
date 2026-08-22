defmodule RelayWeb.Api.CardDependenciesTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards

  setup %{conn: conn} do
    # card_seq starts at 0 and only bumps through Cards.create_card; the factory-inserted cards
    # below claim ref_numbers 1-3 directly, so it is bumped here too or the "POST /api/cards"
    # test's create would collide with card `a`'s ref_number (RE1).
    board = insert(:board, key: "RE", card_seq: 3)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    next_up = insert(:stage, board: board, name: "Next up", category: :unstarted, position: 1)
    done = insert(:stage, board: board, name: "Done", category: :complete, position: 9)

    a = insert(:card, stage: next_up, ref_number: 1, title: "A")
    b = insert(:card, stage: next_up, ref_number: 2, title: "B")
    c = insert(:card, stage: done, ref_number: 3, title: "C", status: :working)

    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, next_up: next_up, a: a, b: b, c: c}
  end

  defp data(conn), do: conn |> json_response(200) |> Map.fetch!("data")

  test "PATCH depends_on replaces the set; show returns both directions", ctx do
    patch(ctx.conn, ~p"/api/cards/RE1", %{depends_on: ["RE2", "RE3"]})

    body = ctx.conn |> get(~p"/api/cards/RE1") |> data()

    assert body["depends_on"] == [
             %{"ref" => "RE2", "title" => "B", "satisfied" => false},
             %{"ref" => "RE3", "title" => "C", "satisfied" => true}
           ]

    assert ctx.conn |> get(~p"/api/cards/RE2") |> data() |> Map.fetch!("blocks") ==
             [%{"ref" => "RE1", "title" => "A"}]
  end

  test "an empty list clears the set", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])

    assert ctx.conn |> patch(~p"/api/cards/RE1", %{depends_on: []}) |> data() |> Map.fetch!("depends_on") == []
  end

  test "the key absent leaves the set untouched", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])

    body = ctx.conn |> patch(~p"/api/cards/RE1", %{title: "A renamed"}) |> data()
    assert body["title"] == "A renamed"
    assert [%{"ref" => "RE2"}] = body["depends_on"]
  end

  test "POST /api/cards accepts depends_on on create", ctx do
    body =
      ctx.conn
      |> post(~p"/api/cards", %{title: "New", stage: ctx.next_up.id, depends_on: ["RE2"]})
      |> json_response(201)
      |> Map.fetch!("data")

    assert [%{"ref" => "RE2"}] = body["depends_on"]
  end

  test "an unknown ref is a 422 naming it, and nothing is applied", ctx do
    body = ctx.conn |> patch(~p"/api/cards/RE1", %{depends_on: ["RE2", "ZZ999"]}) |> json_response(422)

    assert body["error"]["code"] == "unknown_refs"
    assert body["error"]["message"] == "this board has no card with ref: ZZ999"
    assert Cards.list_dependencies(ctx.board, ctx.a) == []
  end

  test "a cycle is a 422 naming the path it would close", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])

    body = ctx.conn |> patch(~p"/api/cards/RE2", %{depends_on: ["RE1"]}) |> json_response(422)

    assert body["error"]["code"] == "dependency_cycle"
    assert body["error"]["message"] == "that would create a dependency cycle: RE2 → RE1 → RE2"
    assert Cards.list_dependencies(ctx.board, ctx.b) == []
  end

  test "a non-list, or a list holding a non-string, is an invalid request", ctx do
    assert ctx.conn |> patch(~p"/api/cards/RE1", %{depends_on: "RE2"}) |> json_response(400)
    assert ctx.conn |> patch(~p"/api/cards/RE1", %{depends_on: [7]}) |> json_response(400)
  end

  test "the index shape is deliberately unchanged", ctx do
    [first | _] = ctx.conn |> get(~p"/api/cards") |> data()

    refute Map.has_key?(first, "depends_on")
    refute Map.has_key?(first, "blocks")
  end
end
