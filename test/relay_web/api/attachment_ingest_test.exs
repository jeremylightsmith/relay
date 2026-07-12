defmodule RelayWeb.Api.AttachmentIngestTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Spec", position: 1)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, stage: stage}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  @png_b64 Base.encode64(<<0x89, ?P, ?N, ?G, "\r\n", 0x1A, "\n", "bytes">>)

  test "POST creates an attachment and returns id/url/markdown", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    data =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/attachments", %{
        filename: "screen.png",
        content_type: "image/png",
        data_base64: @png_b64
      })
      |> json_response(201)
      |> Map.fetch!("data")

    assert is_binary(data["id"])
    assert data["url"] == "/attachments/#{data["id"]}"
    assert data["markdown"] == "![screen.png](/attachments/#{data["id"]})"
  end

  test "a filename containing markdown-special characters produces valid markdown", %{
    conn: conn,
    board: board,
    stage: stage
  } do
    card = insert(:card, stage: stage)

    data =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/attachments", %{
        filename: "weird]name).png",
        content_type: "image/png",
        data_base64: @png_b64
      })
      |> json_response(201)
      |> Map.fetch!("data")

    assert data["markdown"] == "![weird\\]name\\).png](/attachments/#{data["id"]})"

    {:safe, html} = Relay.Markdown.to_html(data["markdown"])
    doc = LazyHTML.from_fragment(html)

    assert doc |> LazyHTML.query("img[src=\"#{data["url"]}\"]") |> Enum.count() == 1
    assert doc |> LazyHTML.query("img[alt=\"weird]name).png\"]") |> Enum.count() == 1
  end

  test "a filename containing an opening bracket produces valid markdown", %{
    conn: conn,
    board: board,
    stage: stage
  } do
    card = insert(:card, stage: stage)

    data =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/attachments", %{
        filename: "a[b.png",
        content_type: "image/png",
        data_base64: @png_b64
      })
      |> json_response(201)
      |> Map.fetch!("data")

    assert data["markdown"] == "![a\\[b.png](/attachments/#{data["id"]})"

    {:safe, html} = Relay.Markdown.to_html(data["markdown"])
    doc = LazyHTML.from_fragment(html)

    assert doc |> LazyHTML.query("img[src=\"#{data["url"]}\"]") |> Enum.count() == 1
    assert doc |> LazyHTML.query("img[alt=\"a[b.png\"]") |> Enum.count() == 1
  end

  test "rejects a non-image content type with 400", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    assert conn
           |> post(~p"/api/cards/#{ref(board, card)}/attachments", %{
             filename: "note.txt",
             content_type: "text/plain",
             data_base64: Base.encode64("hello")
           })
           |> json_response(400)
  end

  test "unknown ref is 404", %{conn: conn} do
    assert conn
           |> post(~p"/api/cards/RLY-9999/attachments", %{
             filename: "screen.png",
             content_type: "image/png",
             data_base64: @png_b64
           })
           |> json_response(404)
  end

  test "another board's card is 404", %{conn: conn, board: board} do
    other = insert(:card, stage: insert(:stage, board: insert(:board)))

    assert conn
           |> post(~p"/api/cards/#{ref(board, other)}/attachments", %{
             filename: "screen.png",
             content_type: "image/png",
             data_base64: @png_b64
           })
           |> json_response(404)
  end

  test "invalid base64 is 400", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)

    assert conn
           |> post(~p"/api/cards/#{ref(board, card)}/attachments", %{
             filename: "screen.png",
             content_type: "image/png",
             data_base64: "!!! not base64 !!!"
           })
           |> json_response(400)
  end
end
