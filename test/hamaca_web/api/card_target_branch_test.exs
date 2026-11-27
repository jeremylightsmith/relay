defmodule HamacaWeb.Api.CardTargetBranchTest do
  use HamacaWeb.ConnCase, async: true

  setup %{conn: conn} do
    # The factory cards claim ref_numbers 1-2 directly, so card_seq is bumped to match or the
    # POST tests' create would collide with card `a`'s ref_number.
    board = insert(:board, key: "RE", card_seq: 2)
    {:ok, %{token: token}} = Hamaca.ApiKeys.create_key(board, board.owner)
    next_up = insert(:stage, board: board, name: "Next up", category: :unstarted, position: 1)
    insert(:stage, board: board, name: "Done", category: :complete, position: 9)

    a = insert(:card, stage: next_up, ref_number: 1, title: "A")
    b = insert(:card, stage: next_up, ref_number: 2, title: "B")

    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, next_up: next_up, a: a, b: b}
  end

  defp data(conn, status \\ 200), do: conn |> json_response(status) |> Map.fetch!("data")
  defp error(conn, status), do: conn |> json_response(status) |> Map.fetch!("error")

  describe "PATCH /api/cards/:ref target_branch" do
    test "a string sets the override", ctx do
      body = ctx.conn |> patch(~p"/api/cards/RE1", %{target_branch: "exp/flows"}) |> data()

      assert body["target_branch"] == "exp/flows"
      assert body["effective_target"] == "exp/flows"
      assert Map.has_key?(body, "target_inherited_from")
      assert body["target_inherited_from"] == nil
    end

    test "null clears the override back to the board default", ctx do
      patch(ctx.conn, ~p"/api/cards/RE1", %{target_branch: "exp/flows"})

      body = ctx.conn |> patch(~p"/api/cards/RE1", %{target_branch: nil}) |> data()

      assert Map.has_key?(body, "target_branch")
      assert body["target_branch"] == nil
      assert body["effective_target"] == "main"
    end

    test "an empty string also clears the override", ctx do
      patch(ctx.conn, ~p"/api/cards/RE1", %{target_branch: "exp/flows"})

      body = ctx.conn |> patch(~p"/api/cards/RE1", %{target_branch: ""}) |> data()

      assert body["target_branch"] == nil
      assert body["effective_target"] == "main"
    end

    test "an active run refuses with 409 run_active and leaves the rest of the PATCH unapplied", ctx do
      insert(:run, card: ctx.a, status: :running)

      err = ctx.conn |> patch(~p"/api/cards/RE1", %{target_branch: "exp/other", title: "new"}) |> error(409)
      assert err["code"] == "run_active"

      reloaded = Hamaca.Repo.reload!(ctx.a)
      assert reloaded.target_branch == nil
      assert reloaded.title == "A"
    end

    test "a bad branch name is 422 invalid", ctx do
      err = ctx.conn |> patch(~p"/api/cards/RE1", %{target_branch: "a b"}) |> error(422)

      assert err["code"] == "invalid"
      assert err["message"] =~ "is not a valid git branch name"
    end

    test "a non-string, non-null value is 400 invalid_request", ctx do
      err = ctx.conn |> patch(~p"/api/cards/RE1", %{target_branch: 5}) |> error(400)

      assert err["code"] == "invalid"
      assert err["message"] == "Invalid request"
    end
  end

  describe "POST /api/cards spawned_from" do
    test "the child inherits the spawner's override", ctx do
      ctx.a |> Ecto.Changeset.change(target_branch: "exp/flows") |> Hamaca.Repo.update!()

      body =
        ctx.conn
        |> post(~p"/api/cards", %{title: "child", stage: ctx.next_up.id, spawned_from: "RE1"})
        |> data(201)

      assert body["target_branch"] == "exp/flows"
      assert body["effective_target"] == "exp/flows"
      assert body["target_inherited_from"] == "RE1"
    end

    test "an unknown spawned_from ref is 422 unknown_spawned_from", ctx do
      err =
        ctx.conn
        |> post(~p"/api/cards", %{title: "child", stage: ctx.next_up.id, spawned_from: "RE9999"})
        |> error(422)

      assert err["code"] == "unknown_spawned_from"
      assert err["message"] =~ "RE9999"
    end
  end

  test "GET /api/cards/:ref carries all three keys, resolved against the board default", ctx do
    body = ctx.conn |> get(~p"/api/cards/RE2") |> data()

    assert Map.has_key?(body, "target_branch")
    assert Map.has_key?(body, "target_inherited_from")
    assert body["target_branch"] == nil
    assert body["target_inherited_from"] == nil
    assert body["effective_target"] == "main"
  end
end
