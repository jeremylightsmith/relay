defmodule RelayWeb.Api.CardTasksTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards
  alias Relay.Repo

  @body ~s{Run it:\n\n```elixir\nIO.puts("hi")\n```\nSay "quoted" back.\n}

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Code", type: :work, position: 1)
    card = insert(:card, stage: stage)
    authed = put_req_header(conn, "authorization", "Bearer " <> token)

    {:ok, conn: authed, bare: conn, board: board, stage: stage, card: card, ref: Cards.ref(board, card)}
  end

  defp add!(card, titles) do
    {:ok, tasks} = Cards.add_tasks(card, Enum.map(titles, &%{"title" => &1, "body" => "body of " <> &1}))
    tasks
  end

  describe "POST /api/cards/:ref/tasks" do
    test "appends the batch in argument order and answers 201 with bodiless summaries",
         %{conn: conn, card: card, ref: ref} do
      [a] = add!(card, ["a"])

      data =
        conn
        |> post(~p"/api/cards/#{ref}/tasks", %{tasks: [%{title: "First", body: @body}, %{title: "Second"}]})
        |> json_response(201)
        |> Map.fetch!("data")

      assert [
               %{"title" => "First", "position" => 1, "done" => false},
               %{"title" => "Second", "position" => 2, "done" => false}
             ] = data

      refute Enum.any?(data, &Map.has_key?(&1, "body"))
      assert [%{id: a_id, body: "body of a"}, %{body: @body}, %{body: nil}] = Cards.list_tasks(card)
      assert a_id == a.id
    end

    test "a blank title anywhere answers 422 and writes nothing", %{conn: conn, card: card, ref: ref} do
      body = %{tasks: [%{title: "ok", body: "x"}, %{title: "", body: "y"}]}

      assert %{"error" => %{"code" => "invalid"}} =
               conn |> post(~p"/api/cards/#{ref}/tasks", body) |> json_response(422)

      assert Cards.list_tasks(card) == []
    end

    test "a missing, empty or malformed tasks list answers 422 invalid_request",
         %{conn: conn, card: card, ref: ref} do
      for body <- [%{}, %{tasks: []}, %{tasks: "nope"}, %{tasks: ["a string"]}] do
        assert %{"error" => %{"code" => "invalid_request"}} =
                 conn |> post(~p"/api/cards/#{ref}/tasks", body) |> json_response(422)
      end

      assert Cards.list_tasks(card) == []
    end
  end

  describe "GET /api/cards/:ref/tasks" do
    test "lists summaries in position order with no body key", %{conn: conn, card: card, ref: ref} do
      [a, b] = add!(card, ["A", "B"])

      data = conn |> get(~p"/api/cards/#{ref}/tasks") |> json_response(200) |> Map.fetch!("data")

      assert Enum.map(data, & &1["id"]) == [a.id, b.id]
      assert Enum.all?(data, &(&1 |> Map.keys() |> Enum.sort() == ~w(done id position title)))
    end
  end

  describe "GET /api/cards/:ref/tasks/:id" do
    test "returns the task with its body verbatim", %{conn: conn, card: card, ref: ref} do
      {:ok, [t]} = Cards.add_tasks(card, [%{"title" => "T", "body" => @body}])

      assert %{"id" => id, "title" => "T", "body" => @body, "done" => false, "position" => 0} =
               conn |> get(~p"/api/cards/#{ref}/tasks/#{t.id}") |> json_response(200) |> Map.fetch!("data")

      assert id == t.id
    end
  end

  describe "PATCH /api/cards/:ref/tasks/:id" do
    test "updates title and body of that task only; done cannot be set here",
         %{conn: conn, card: card, ref: ref} do
      [a, b] = add!(card, ["A", "B"])
      {:ok, _} = Cards.set_sub_task_done(card, a.id, true)

      data =
        conn
        |> patch(~p"/api/cards/#{ref}/tasks/#{b.id}", %{title: "B2", body: @body, done: true})
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{"title" => "B2", "body" => @body, "done" => false, "position" => 1} = data
      assert [%{title: "A", body: "body of A", done: true}, %{title: "B2", done: false}] = Cards.list_tasks(card)
    end

    test "neither title nor body answers 422 invalid_request", %{conn: conn, card: card, ref: ref} do
      [a] = add!(card, ["A"])

      assert %{"error" => %{"code" => "invalid_request"}} =
               conn |> patch(~p"/api/cards/#{ref}/tasks/#{a.id}", %{done: true}) |> json_response(422)
    end

    test "a blank title answers 422 and leaves the row", %{conn: conn, card: card, ref: ref} do
      [a] = add!(card, ["A"])

      assert %{"error" => %{"code" => "invalid"}} =
               conn |> patch(~p"/api/cards/#{ref}/tasks/#{a.id}", %{title: ""}) |> json_response(422)

      assert [%{title: "A"}] = Cards.list_tasks(card)
    end
  end

  describe "DELETE /api/cards/:ref/tasks/:id" do
    test "removes the task, answers its summary, and closes the gap", %{conn: conn, card: card, ref: ref} do
      [a, b, c] = add!(card, ["A", "B", "C"])

      data = conn |> delete(~p"/api/cards/#{ref}/tasks/#{b.id}") |> json_response(200) |> Map.fetch!("data")

      assert %{"id" => id, "title" => "B", "position" => 1} = data
      assert id == b.id
      refute Map.has_key?(data, "body")
      assert Enum.map(Cards.list_tasks(card), &{&1.id, &1.position}) == [{a.id, 0}, {c.id, 1}]
    end
  end

  describe "404s" do
    test "a task on another card is not found through this card, and is untouched",
         %{conn: conn, stage: stage, ref: ref} do
      [x] = add!(insert(:card, stage: stage), ["X"])

      assert conn |> get(~p"/api/cards/#{ref}/tasks/#{x.id}") |> json_response(404)
      assert conn |> patch(~p"/api/cards/#{ref}/tasks/#{x.id}", %{title: "hijack"}) |> json_response(404)
      assert conn |> delete(~p"/api/cards/#{ref}/tasks/#{x.id}") |> json_response(404)
      assert Repo.get!(Schemas.SubTask, x.id).title == "X"
    end

    test "an unknown card ref is 404 on every route", %{conn: conn} do
      assert conn |> get(~p"/api/cards/NOPE999/tasks") |> json_response(404)
      assert conn |> post(~p"/api/cards/NOPE999/tasks", %{tasks: [%{title: "T"}]}) |> json_response(404)
      assert conn |> get(~p"/api/cards/NOPE999/tasks/1") |> json_response(404)
    end

    test "a non-integer task id is 404, not a crash", %{conn: conn, ref: ref} do
      assert conn |> get(~p"/api/cards/#{ref}/tasks/abc") |> json_response(404)
      assert conn |> patch(~p"/api/cards/#{ref}/tasks/abc", %{title: "x"}) |> json_response(404)
      assert conn |> delete(~p"/api/cards/#{ref}/tasks/abc") |> json_response(404)
    end
  end

  test "GET /api/cards/:ref exposes each task's body", %{conn: conn, card: card, ref: ref} do
    {:ok, [_t]} = Cards.add_tasks(card, [%{"title" => "T", "body" => @body}])

    assert [%{"title" => "T", "body" => @body}] =
             conn |> get(~p"/api/cards/#{ref}") |> json_response(200) |> get_in(["data", "sub_tasks"])
  end

  test "the task routes require an API key", %{bare: bare, ref: ref} do
    assert bare |> get(~p"/api/cards/#{ref}/tasks") |> json_response(401)
    assert bare |> post(~p"/api/cards/#{ref}/tasks", %{tasks: [%{title: "T"}]}) |> json_response(401)
  end
end
