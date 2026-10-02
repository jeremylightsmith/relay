defmodule Relay.AttachmentsTest do
  use Relay.DataCase, async: true

  alias Relay.Attachments
  alias Schemas.Attachment

  @png <<0x89, ?P, ?N, ?G, "\r\n", 0x1A, "\n", "fake-bytes">>

  describe "create_attachment/2" do
    test "stores bytes and inserts a metadata row for a valid image" do
      card = insert(:card)

      assert {:ok, %Attachment{} = attachment} =
               Attachments.create_attachment(card, %{
                 filename: "screen.png",
                 content_type: "image/png",
                 bytes: @png
               })

      assert attachment.card_id == card.id
      assert attachment.content_type == "image/png"
      assert attachment.byte_size == byte_size(@png)
      assert Attachments.fetch_bytes(attachment) == {:ok, @png}
    end

    test "rejects bytes over 5 MB" do
      card = insert(:card)
      big = :binary.copy(<<0>>, 5_242_881)

      assert {:error, changeset} =
               Attachments.create_attachment(card, %{
                 filename: "big.png",
                 content_type: "image/png",
                 bytes: big
               })

      assert %{byte_size: [_ | _]} = errors_on(changeset)
    end

    test "rejects a non-image content type" do
      card = insert(:card)

      assert {:error, changeset} =
               Attachments.create_attachment(card, %{
                 filename: "note.txt",
                 content_type: "text/plain",
                 bytes: "hello"
               })

      assert %{content_type: [_ | _]} = errors_on(changeset)
    end

    test "accepts a self-contained HTML mockup (RE370)" do
      card = insert(:card)
      html = "<!doctype html><p>Empty state</p>"

      assert {:ok, %Attachment{} = attachment} =
               Attachments.create_attachment(card, %{
                 filename: "empty.html",
                 content_type: Attachment.html_type(),
                 bytes: html
               })

      assert Attachment.html?(attachment)
      assert Attachments.fetch_bytes(attachment) == {:ok, html}
    end

    test "rejects HTML over 5 MB (RE370)" do
      card = insert(:card)

      assert {:error, changeset} =
               Attachments.create_attachment(card, %{
                 filename: "big.html",
                 content_type: Attachment.html_type(),
                 bytes: :binary.copy("a", 5_242_881)
               })

      assert %{byte_size: [_ | _]} = errors_on(changeset)
    end
  end

  describe "get_attachment/1 and fetch_bytes/1" do
    test "round-trips bytes through the storage adapter" do
      card = insert(:card)

      {:ok, attachment} =
        Attachments.create_attachment(card, %{
          filename: "screen.png",
          content_type: "image/png",
          bytes: @png
        })

      fetched = Attachments.get_attachment(attachment.id)
      assert fetched.id == attachment.id
      assert Attachments.fetch_bytes(fetched) == {:ok, @png}
    end

    test "returns nil for an unknown or malformed id" do
      assert Attachments.get_attachment(Ecto.UUID.generate()) == nil
      assert Attachments.get_attachment("not-a-uuid") == nil
    end
  end

  describe "get_attachment/2 (RE370)" do
    test "returns the member's attachment with its card and board preloaded" do
      board = insert(:board)
      card = insert(:card, stage: insert(:stage, board: board))
      member = insert(:user)
      insert(:membership, board: board, user: member)

      {:ok, attachment} =
        Attachments.create_attachment(card, %{filename: "m.html", content_type: Attachment.html_type(), bytes: "<p>x</p>"})

      assert %Attachment{card: %Schemas.Card{id: card_id, board: %Schemas.Board{id: board_id}}} =
               Attachments.get_attachment(member, attachment.id)

      assert card_id == card.id
      assert board_id == board.id
      assert Attachments.get_attachment(insert(:user), attachment.id) == nil
    end
  end
end
