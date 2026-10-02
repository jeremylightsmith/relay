defmodule RelayWeb.Api.AttachmentControllerTest do
  @moduledoc """
  RE373 — `GET /api/attachments/:id` hands an attachment's raw bytes to a board API key, so the
  next agent on a card (`./relay mockups REF --pull`) can read what an earlier one uploaded. Scoped
  to the key's board: anything else is a 404, never a 403, so an id on another board is not
  revealed.
  """
  use RelayWeb.ConnCase, async: true

  alias Relay.Attachments
  alias RelayWeb.AttachmentController
  alias Schemas.Attachment

  @png <<0x89, ?P, ?N, ?G, "\r\n", 0x1A, "\n", "fake-bytes">>
  @html ~s|<!doctype html><p id="t">mock</p><script>document.title = "x"</script>|

  setup do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    card = insert(:card, stage: insert(:stage, board: board))

    {:ok, html} =
      Attachments.create_attachment(card, %{
        filename: ~s|mock "v1".html|,
        content_type: Attachment.html_type(),
        bytes: @html
      })

    {:ok, png} = Attachments.create_attachment(card, %{filename: "screen.png", content_type: "image/png", bytes: @png})

    {:ok, token: token, card: card, html: html, png: png}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "serves an HTML mockup's exact bytes under the sandbox CSP", %{conn: conn, token: token, html: html} do
    conn = conn |> authed(token) |> get(Attachment.api_path(html.id))

    assert response(conn, 200) == @html
    assert conn |> get_resp_header("content-type") |> List.first() =~ "text/html"
    assert get_resp_header(conn, "content-security-policy") == [AttachmentController.html_csp()]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-disposition") == [~s|attachment; filename="mock _v1_.html"|]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
  end

  test "serves an image with its stored content type", %{conn: conn, token: token, png: png} do
    conn = conn |> authed(token) |> get(Attachment.api_path(png.id))

    assert response(conn, 200) == @png
    assert conn |> get_resp_header("content-type") |> List.first() =~ "image/png"
    assert get_resp_header(conn, "content-disposition") == [~s|attachment; filename="screen.png"|]
  end

  test "another board's key gets a 404, not a 403", %{conn: conn, html: html} do
    other = insert(:board)
    {:ok, %{token: other_token}} = Relay.ApiKeys.create_key(other, other.owner)

    conn = conn |> authed(other_token) |> get(Attachment.api_path(html.id))

    assert json_response(conn, 404)["error"]["code"] == "not_found"
  end

  test "no key or an invalid key is 401", %{conn: conn, html: html} do
    assert conn |> get(Attachment.api_path(html.id)) |> json_response(401)
    assert build_conn() |> authed("garbage") |> get(Attachment.api_path(html.id)) |> json_response(401)
  end

  test "an unknown or malformed id is 404", %{conn: conn, token: token} do
    assert conn |> authed(token) |> get(Attachment.api_path(Ecto.UUID.generate())) |> json_response(404)
    assert build_conn() |> authed(token) |> get(Attachment.api_path("not-a-uuid")) |> json_response(404)
  end

  test "a row whose bytes are missing from storage is 404", %{conn: conn, token: token, card: card} do
    # The factory writes metadata only — no bytes — so fetch_bytes/1 misses.
    orphan = insert(:attachment, card: card)

    assert conn |> authed(token) |> get(Attachment.api_path(orphan.id)) |> json_response(404)
  end
end
