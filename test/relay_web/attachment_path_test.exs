defmodule RelayWeb.AttachmentPathTest do
  @moduledoc """
  RE322 — `RelayWeb.attachment_path/1` is the one definition of where an uploaded attachment is
  served. The router's `get "/attachments/:id"` can't call a function, so it is the only other
  spelling; the route test below pins the two together so they can never drift.
  """
  use ExUnit.Case, async: true

  describe "attachment_path/1" do
    test "builds the path an uploaded attachment is served from" do
      assert RelayWeb.attachment_path("abc-123") == "/attachments/abc-123"
    end

    test "the router serves exactly that path with AttachmentController.show" do
      path = RelayWeb.attachment_path(Ecto.UUID.generate())

      assert %{plug: RelayWeb.AttachmentController, plug_opts: :show} =
               Phoenix.Router.route_info(RelayWeb.Router, "GET", path, "localhost")
    end
  end

  describe "attachment_path?/1" do
    test "recognises a path built by attachment_path/1" do
      assert RelayWeb.attachment_path?(RelayWeb.attachment_path(Ecto.UUID.generate()))
    end

    test "rejects anything that is not an attachment path with a single-segment id" do
      for path <- [
            "/attachments",
            "/attachments/",
            "/attachments/a/b",
            "attachments/abc",
            "/Users/me/tmp/attachments/x.png",
            "/images/logo_light_128.png",
            nil,
            42
          ] do
        refute RelayWeb.attachment_path?(path), "expected #{inspect(path)} to be rejected"
      end
    end
  end
end
