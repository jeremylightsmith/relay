defmodule RelayWeb.Api.RunControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Code", position: 1)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, stage: stage}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  test "lists the card's runs newest first with their executions", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)
    older = insert(:run, card: card, status: :failed, flow_key: "spec")
    newer = insert(:run, card: card, status: :cancelled, flow_key: "code")
    insert(:node_execution, run: newer, node_key: "implement", outcome: :succeeded)

    [first, second] = conn |> get(~p"/api/cards/#{ref(board, card)}/runs") |> json_response(200) |> Map.fetch!("data")

    assert first["id"] == newer.id
    assert first["flow_key"] == "code"
    assert second["id"] == older.id
    assert [execution] = first["node_executions"]
    assert execution["node_key"] == "implement"
    assert execution["outcome"] == "succeeded"
  end

  test "a multi-KB detail round-trips byte-for-byte, never truncated", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)
    run = insert(:run, card: card, status: :failed)

    detail =
      Enum.map_join(1..40, "\n\n", fn i ->
        "Paragraph #{i}: " <> String.duplicate("finding text with \"quotes\" and — dashes. ", 20)
      end)

    assert byte_size(detail) > 2_000
    insert(:node_execution, run: run, node_key: "final_review", outcome: :failed, detail: detail)

    [body] = conn |> get(~p"/api/cards/#{ref(board, card)}/runs") |> json_response(200) |> Map.fetch!("data")

    assert [%{"detail" => returned, "node_key" => "final_review", "outcome" => "failed"}] = body["node_executions"]
    assert returned == detail
  end

  test "every serialized field the operator needs is present", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)
    run = insert(:run, card: card)
    sub_task = insert(:sub_task, card: card)

    insert(:node_execution,
      run: run,
      git_sha: "abc123",
      session_id: "sess-1",
      sub_task_id: sub_task.id,
      visit: 2,
      attempt: 3
    )

    [body] = conn |> get(~p"/api/cards/#{ref(board, card)}/runs") |> json_response(200) |> Map.fetch!("data")
    [execution] = body["node_executions"]

    for key <- ~w(node_key visit attempt outcome detail failure_signature git_sha
                  session_id cost sub_task_id started_at finished_at) do
      assert Map.has_key?(execution, key), "execution should serialize #{key}"
    end

    for key <- ~w(id flow_key status parked_reason current_node failure_detail started_at finished_at) do
      assert Map.has_key?(body, key), "run should serialize #{key}"
    end
  end

  test "another board's card is 404", %{conn: conn} do
    other_board = insert(:board, key: "OTH")
    other_stage = insert(:stage, board: other_board, position: 1)
    other_card = insert(:card, stage: other_stage)

    assert conn |> get(~p"/api/cards/#{Cards.ref(other_board, other_card)}/runs") |> json_response(404)
  end
end
