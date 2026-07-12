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
end
