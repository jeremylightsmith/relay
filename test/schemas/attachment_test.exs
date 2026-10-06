defmodule Schemas.AttachmentTest do
  use ExUnit.Case, async: true

  alias Schemas.Attachment

  describe "html_type/0 and html?/1 (RE370)" do
    test "html? answers for a content type and for an attachment" do
      assert Attachment.html?(Attachment.html_type())
      assert Attachment.html?(%Attachment{content_type: Attachment.html_type()})
      refute Attachment.html?("image/png")
      refute Attachment.html?(%Attachment{content_type: "image/png"})
      refute Attachment.html?(nil)
    end
  end

  describe "image_types/0 and mockup_types/0 (RE390)" do
    test "image_types/0 is the image content types and mockup_types/0 adds HTML" do
      assert Attachment.image_types() == ["image/png", "image/jpeg", "image/webp", "image/gif"]
      assert Attachment.mockup_types() == ["image/png", "image/jpeg", "image/webp", "image/gif", "text/html"]
    end
  end

  describe "path/1, id_from_path/1, path?/1 — the domain-side definition of the attachment url" do
    test "path/1 builds the served path and id_from_path/1 inverts it" do
      id = Ecto.UUID.generate()
      assert Attachment.path(id) == "/attachments/" <> id
      assert Attachment.id_from_path(Attachment.path(id)) == {:ok, id}
      assert Attachment.path?(Attachment.path(id))
    end

    test "anything that is not a single-segment attachment path is refused" do
      for path <- [
            "/attachments",
            "/attachments/",
            "/attachments/a/b",
            "attachments/abc",
            "/attachments/abc/view",
            "https://example.com/x.html",
            nil,
            42
          ] do
        assert Attachment.id_from_path(path) == :error, "expected #{inspect(path)} to be refused"
        refute Attachment.path?(path)
      end
    end
  end

  describe "changeset/2 content types (RE370)" do
    defp changeset(content_type, byte_size \\ 10) do
      Attachment.changeset(%Attachment{card_id: 1}, %{
        filename: "f",
        content_type: content_type,
        byte_size: byte_size,
        storage_key: "k"
      })
    end

    test "accepts HTML alongside the image types" do
      assert changeset(Attachment.html_type()).valid?
      assert changeset("image/png").valid?
    end

    test "still refuses other non-image types and HTML over 5 MB" do
      refute changeset("text/plain").valid?
      refute changeset("application/javascript").valid?
      refute changeset(Attachment.html_type(), 5_242_881).valid?
    end
  end
end
