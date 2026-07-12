defmodule RelayWeb.AttachmentControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Attachments

  @png <<0x89, ?P, ?N, ?G, "\r\n", 0x1A, "\n", "fake-bytes">>

  setup do
    card = insert(:card)

    {:ok, attachment} =
      Attachments.create_attachment(card, %{
        filename: "screen.png",
        content_type: "image/png",
        bytes: @png
      })

    {:ok, attachment: attachment}
  end

  test "serves the bytes with content-type and an immutable cache header", %{conn: conn, attachment: attachment} do
    conn = conn |> log_in_user() |> get(~p"/attachments/#{attachment.id}")

    assert response(conn, 200) == @png
    assert conn |> get_resp_header("content-type") |> List.first() =~ "image/png"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "unknown id is 404", %{conn: conn} do
    conn = conn |> log_in_user() |> get(~p"/attachments/#{Ecto.UUID.generate()}")
    assert response(conn, 404)
  end

  test "unauthenticated request is redirected", %{conn: conn, attachment: attachment} do
    conn = get(conn, ~p"/attachments/#{attachment.id}")
    assert redirected_to(conn) =~ "/"
  end
end
