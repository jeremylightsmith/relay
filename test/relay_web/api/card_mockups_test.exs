defmodule RelayWeb.Api.CardMockupsTest do
  @moduledoc """
  RE370 — `relay mockups` PATCHes `{"mockups": [...]}` here after uploading each file through
  `POST /api/cards/:ref/attachments`. Replace semantics; a url that is not an HTML attachment on
  this card is `422 invalid_mockups` naming the entry, and nothing is written.
  """
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Design", type: :work, ai_enabled: true, position: 1)
    card = insert(:card, stage: stage)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn, board: board, stage: stage, card: card, ref: Cards.ref(board, card)}
  end

  defp upload(conn, ref, filename, content_type \\ Schemas.Attachment.html_type()) do
    body = %{"filename" => filename, "content_type" => content_type, "data_base64" => Base.encode64("<p>#{filename}</p>")}
    conn |> post(~p"/api/cards/#{ref}/attachments", Jason.encode!(body)) |> json_response(201) |> get_in(["data", "url"])
  end

  defp patch_mockups(conn, ref, mockups), do: patch(conn, ~p"/api/cards/#{ref}", Jason.encode!(%{"mockups" => mockups}))

  test "the upload endpoint accepts text/html", %{conn: conn, ref: ref} do
    assert "/attachments/" <> _id = upload(conn, ref, "mock.html")
  end

  test "a card with no mockups shows an empty list", %{conn: conn, ref: ref} do
    assert conn |> get(~p"/api/cards/#{ref}") |> json_response(200) |> get_in(["data", "mockups"]) == []
  end

  test "PATCH sets the list, GET shows it, a second PATCH replaces it", %{conn: conn, ref: ref} do
    a = upload(conn, ref, "a.html")
    b = upload(conn, ref, "b.html")

    set = conn |> patch_mockups(ref, [%{"url" => a, "caption" => "Empty state"}]) |> json_response(200)
    assert set["data"]["mockups"] == [%{"url" => a, "caption" => "Empty state"}]

    replaced = conn |> patch_mockups(ref, [%{"url" => b, "caption" => "b.html"}]) |> json_response(200)
    assert replaced["data"]["mockups"] == [%{"url" => b, "caption" => "b.html"}]

    shown = conn |> get(~p"/api/cards/#{ref}") |> json_response(200)
    assert shown["data"]["mockups"] == [%{"url" => b, "caption" => "b.html"}]
  end

  test "an empty list and null both clear", %{conn: conn, ref: ref} do
    a = upload(conn, ref, "a.html")
    conn |> patch_mockups(ref, [%{"url" => a}]) |> json_response(200)
    assert conn |> patch_mockups(ref, []) |> json_response(200) |> get_in(["data", "mockups"]) == []

    conn |> patch_mockups(ref, [%{"url" => a}]) |> json_response(200)
    assert conn |> patch_mockups(ref, nil) |> json_response(200) |> get_in(["data", "mockups"]) == []
  end

  test "another card's attachment is 422 invalid_mockups and nothing is written",
       %{conn: conn, board: board, stage: stage, ref: ref} do
    other_ref = Cards.ref(board, insert(:card, stage: stage))
    theirs = upload(conn, other_ref, "theirs.html")

    body = conn |> patch_mockups(ref, [%{"url" => theirs}]) |> json_response(422)

    assert body["error"]["code"] == "invalid_mockups"
    assert body["error"]["message"] =~ "mockups[0]"
    assert conn |> get(~p"/api/cards/#{ref}") |> json_response(200) |> get_in(["data", "mockups"]) == []
  end

  test "a non-HTML attachment is 422", %{conn: conn, ref: ref} do
    png = upload(conn, ref, "shot.png", "image/png")

    assert conn |> patch_mockups(ref, [%{"url" => png}]) |> json_response(422) |> get_in(["error", "code"]) ==
             "invalid_mockups"
  end

  test "a non-list mockups is 400", %{conn: conn, ref: ref} do
    assert conn |> patch_mockups(ref, "nope") |> json_response(400)
  end
end
