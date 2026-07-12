defmodule RelayWeb.AttachmentControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Attachments

  @png <<0x89, ?P, ?N, ?G, "\r\n", 0x1A, "\n", "fake-bytes">>

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    card = insert(:card, stage: stage)
    member = insert(:user)
    insert(:membership, board: board, user: member)

    {:ok, attachment} =
      Attachments.create_attachment(card, %{
        filename: "screen.png",
        content_type: "image/png",
        bytes: @png
      })

    {:ok, attachment: attachment, board: board, member: member}
  end

  test "serves the bytes with content-type and an immutable cache header", %{
    conn: conn,
    attachment: attachment,
    member: member
  } do
    conn = conn |> log_in_user(member) |> get(~p"/attachments/#{attachment.id}")

    assert response(conn, 200) == @png
    assert conn |> get_resp_header("content-type") |> List.first() =~ "image/png"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "unknown id is 404", %{conn: conn} do
    conn = conn |> log_in_user() |> get(~p"/attachments/#{Ecto.UUID.generate()}")
    assert response(conn, 404)
  end

  test "an authenticated user who isn't a member of the attachment's board gets 404", %{
    conn: conn,
    attachment: attachment
  } do
    conn = conn |> log_in_user() |> get(~p"/attachments/#{attachment.id}")
    assert response(conn, 404)
  end

  test "unauthenticated request is redirected", %{conn: conn, attachment: attachment} do
    conn = get(conn, ~p"/attachments/#{attachment.id}")
    assert redirected_to(conn) =~ "/"
  end
end
