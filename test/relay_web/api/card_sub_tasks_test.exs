defmodule RelayWeb.Api.CardSubTasksTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Code", owner: :ai, position: 1)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, stage: stage}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  test "PATCH sub_tasks creates the checklist; show returns items + progress",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{
        sub_tasks: [%{"title" => "A"}, %{"title" => "B", "done" => true}]
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["sub_task_progress"] == %{"done" => 1, "total" => 2}

    assert [
             %{"title" => "A", "done" => false, "position" => 0},
             %{"title" => "B", "done" => true, "position" => 1}
           ] = Enum.sort_by(body["sub_tasks"], & &1["position"])
  end

  test "PATCH /sub-tasks/:id toggles one item", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)
    {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "A"}])
    [a] = card.sub_tasks

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}/sub-tasks/#{a.id}", %{done: true})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["sub_task_progress"] == %{"done" => 1, "total" => 1}
    assert Enum.find(body["sub_tasks"], &(&1["id"] == a.id))["done"] == true
  end

  test "PATCH /sub-tasks/:id for an unknown id returns 404",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    assert conn
           |> patch(~p"/api/cards/#{ref(board, card)}/sub-tasks/999999", %{done: true})
           |> json_response(404)
  end

  test "PATCH /sub-tasks/:id without a boolean done returns 400",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)
    {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "A"}])
    [a] = card.sub_tasks

    assert conn |> patch(~p"/api/cards/#{ref(board, card)}/sub-tasks/#{a.id}", %{}) |> json_response(400)
  end

  test "PATCH ai_result stores the blob; data returns it",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{
        ai_result: %{"summary" => "Shipped", "changes" => ["x"]}
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["ai_result"] == %{"summary" => "Shipped", "changes" => ["x"]}
  end

  test "GET /api/cards index includes sub_task_progress and ai_result",
       %{conn: conn, stage: stage} do
    card = insert(:card, stage: stage)
    {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "A"}])
    {:ok, _} = Cards.update_ai_result(card, %{"summary" => "hi"})

    [json] = conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data")
    assert json["sub_task_progress"] == %{"done" => 0, "total" => 1}
    assert json["ai_result"] == %{"summary" => "hi"}
  end
end
