defmodule RelayWeb.Api.CardAiResultTest do
  @moduledoc """
  `relay result <ref> @file` PATCHes the blob here. A shape the drawer can't read comes back
  422 `invalid_ai_result` with a message naming the offending key, so the agent that wrote it
  fixes the file instead of shipping a card whose Screenshots strip is silently empty.
  """
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, stage: stage}
  end

  defp patch_ai_result(conn, board, card, blob),
    do: patch(conn, ~p"/api/cards/#{Cards.ref(board, card)}", %{ai_result: blob})

  test "the documented shape round-trips", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)
    blob = %{"summary" => "Shipped", "changes" => ["Adds the door"], "screens" => [%{"url" => "/a.png"}]}

    body = conn |> patch_ai_result(board, card, blob) |> json_response(200) |> Map.fetch!("data")

    assert body["ai_result"] == blob
  end

  test "a screen key the drawer never reads is 422, not a silently empty strip",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    blob = %{
      "summary" => "Shipped",
      "screens" => [%{"caption" => "The door", "image" => "/attachments/abc", "name" => "Sign in"}]
    }

    body = conn |> patch_ai_result(board, card, blob) |> json_response(422)

    assert body["error"]["code"] == "invalid_ai_result"
    assert body["error"]["message"] =~ ~s("image")
    assert Cards.get_card_by_ref(board, Cards.ref(board, card)).ai_result == nil
  end

  test "an unknown top-level key is 422 and names the keys that exist",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    body =
      conn
      |> patch_ai_result(board, card, %{"summary" => "Shipped", "deploy_url" => "https://example.com"})
      |> json_response(422)

    assert body["error"]["code"] == "invalid_ai_result"
    assert body["error"]["message"] =~ ~s("deploy_url")
    assert body["error"]["message"] =~ ~s("screens")
  end

  test "a non-object ai_result is still a plain 400 invalid request",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    assert conn |> patch_ai_result(board, card, ["summary"]) |> json_response(400)
  end
end
