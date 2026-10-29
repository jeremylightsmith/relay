defmodule HamacaWeb.Api.CardMockupsTest do
  @moduledoc """
  RE370 — `relay mockups` PATCHes `{"mockups": [...]}` here after uploading each file through
  `POST /api/cards/:ref/attachments`. Replace semantics; a url that is not an HTML or image
  attachment on this card is `422 invalid_mockups` naming the entry, and nothing is written.
  """
  use HamacaWeb.ConnCase, async: true

  alias Hamaca.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Hamaca.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Design", type: :work, position: 1)
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

  test "an image attachment on this card is a mockup (RE390)", %{conn: conn, ref: ref} do
    png = upload(conn, ref, "shot.png", "image/png")

    assert conn
           |> patch_mockups(ref, [%{"url" => png, "caption" => "Empty state"}])
           |> json_response(200)
           |> get_in(["data", "mockups"]) ==
             [%{"url" => png, "caption" => "Empty state"}]
  end

  test "a non-list mockups is 400", %{conn: conn, ref: ref} do
    assert conn |> patch_mockups(ref, "nope") |> json_response(400)
  end

  # RE499 — append one or more mockups, or unlist one, without re-sending the list.
  describe "POST /api/cards/:ref/mockups and DELETE /api/cards/:ref/mockups/:attachment_id" do
    defp post_mockups(conn, ref, body), do: post(conn, ~p"/api/cards/#{ref}/mockups", Jason.encode!(body))

    defp delete_mockup(conn, ref, id), do: delete(conn, ~p"/api/cards/#{ref}/mockups/#{id}")

    defp shown_mockups(conn, ref),
      do: conn |> get(~p"/api/cards/#{ref}") |> json_response(200) |> get_in(["data", "mockups"])

    defp id_of(url), do: url |> Schemas.Attachment.id_from_path() |> elem(1)

    setup %{conn: conn, ref: ref} do
      {:ok, a: upload(conn, ref, "a.html"), b: upload(conn, ref, "b.html")}
    end

    test "POST appends to the list", %{conn: conn, ref: ref, a: a, b: b} do
      conn |> patch_mockups(ref, [%{"url" => a, "caption" => "One"}]) |> json_response(200)

      body = conn |> post_mockups(ref, %{"mockups" => [%{"url" => b, "caption" => "X"}]}) |> json_response(200)

      expected = [%{"url" => a, "caption" => "One"}, %{"url" => b, "caption" => "X"}]
      assert body["data"]["mockups"] == expected
      assert shown_mockups(conn, ref) == expected
    end

    test "re-POSTing an attachment already listed is 422 and nothing changes", %{conn: conn, ref: ref, a: a, b: b} do
      conn |> patch_mockups(ref, [%{"url" => a, "caption" => "One"}]) |> json_response(200)
      conn |> post_mockups(ref, %{"mockups" => [%{"url" => b, "caption" => "X"}]}) |> json_response(200)

      body = conn |> post_mockups(ref, %{"mockups" => [%{"url" => b, "caption" => "X"}]}) |> json_response(422)

      assert body["error"]["code"] == "invalid_mockups"
      assert body["error"]["message"] =~ b
      assert shown_mockups(conn, ref) == [%{"url" => a, "caption" => "One"}, %{"url" => b, "caption" => "X"}]
    end

    test "an empty list is 422; a missing or non-list mockups is 400", %{conn: conn, ref: ref} do
      assert conn |> post_mockups(ref, %{"mockups" => []}) |> json_response(422) |> get_in(["error", "code"]) ==
               "invalid_mockups"

      # The API-wide 400 code is "invalid" (priv/docs/api.md), the same PATCH's non-list mockups
      # returns — chosen over the task body's "invalid_request" by human guidance on RE499.
      assert conn |> post_mockups(ref, %{}) |> json_response(400) |> get_in(["error", "code"]) == "invalid"

      assert conn |> post_mockups(ref, %{"mockups" => "x"}) |> json_response(400) |> get_in(["error", "code"]) ==
               "invalid"
    end

    test "DELETE unlists one; repeating it is 404", %{conn: conn, ref: ref, a: a, b: b} do
      conn |> patch_mockups(ref, [%{"url" => a}, %{"url" => b}]) |> json_response(200)

      body = conn |> delete_mockup(ref, id_of(a)) |> json_response(200)
      assert body["data"]["mockups"] == [%{"url" => b, "caption" => nil}]

      assert conn |> delete_mockup(ref, id_of(a)) |> json_response(404) |> get_in(["error", "code"]) == "not_found"
    end

    test "an unknown card is 404 for both", %{conn: conn, board: board, a: a} do
      unknown = board.key <> "9999"

      assert conn
             |> post_mockups(unknown, %{"mockups" => [%{"url" => a}]})
             |> json_response(404)
             |> get_in(["error", "code"]) ==
               "not_found"

      assert conn |> delete_mockup(unknown, id_of(a)) |> json_response(404) |> get_in(["error", "code"]) == "not_found"
    end

    test "another board's key gets a 404 for both and nothing changes", %{conn: conn, ref: ref, a: a, b: b} do
      conn |> patch_mockups(ref, [%{"url" => a}]) |> json_response(200)

      other = insert(:board)
      {:ok, %{token: other_token}} = Hamaca.ApiKeys.create_key(other, other.owner)

      other_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> other_token)
        |> put_req_header("content-type", "application/json")

      assert other_conn
             |> post_mockups(ref, %{"mockups" => [%{"url" => b}]})
             |> json_response(404)
             |> get_in(["error", "code"]) ==
               "not_found"

      assert other_conn |> delete_mockup(ref, id_of(a)) |> json_response(404) |> get_in(["error", "code"]) ==
               "not_found"

      assert shown_mockups(conn, ref) == [%{"url" => a, "caption" => nil}]
    end
  end
end
