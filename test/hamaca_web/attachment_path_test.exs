defmodule HamacaWeb.AttachmentPathTest do
  @moduledoc """
  RE322 — `HamacaWeb.attachment_path/1` is the one definition of where an uploaded attachment is
  served. The router's `get "/attachments/:id"` can't call a function, so it is the only other
  spelling; the route test below pins the two together so they can never drift.
  """
  use ExUnit.Case, async: true

  describe "attachment_path/1" do
    test "builds the path an uploaded attachment is served from" do
      assert HamacaWeb.attachment_path("abc-123") == "/attachments/abc-123"
    end

    test "the router serves exactly that path with AttachmentController.show" do
      path = HamacaWeb.attachment_path(Ecto.UUID.generate())

      assert %{plug: HamacaWeb.AttachmentController, plug_opts: :show} =
               Phoenix.Router.route_info(HamacaWeb.Router, "GET", path, "localhost")
    end
  end

  describe "attachment_path?/1" do
    test "recognises a path built by attachment_path/1" do
      assert HamacaWeb.attachment_path?(HamacaWeb.attachment_path(Ecto.UUID.generate()))
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
        refute HamacaWeb.attachment_path?(path), "expected #{inspect(path)} to be rejected"
      end
    end
  end

  describe "the domain-side definition (RE370)" do
    test "HamacaWeb's helpers are the schema's, not a second copy" do
      id = Ecto.UUID.generate()
      assert HamacaWeb.attachment_path(id) == Schemas.Attachment.path(id)
      assert HamacaWeb.attachment_path?(Schemas.Attachment.path(id))
    end
  end

  describe "the retired RE370 mockup link (RE487)" do
    # Scenario 6
    test "/attachments/:id/view is not a route, and its path helper is gone" do
      path = "/attachments/#{Ecto.UUID.generate()}/view"

      assert Phoenix.Router.route_info(HamacaWeb.Router, "GET", path, "localhost") == :error
      refute function_exported?(HamacaWeb, :attachment_view_path, 1)
    end
  end

  describe "Schemas.Attachment.api_path/1 (RE373)" do
    test "builds the bearer-authed download path" do
      assert Schemas.Attachment.api_path("abc-123") == "/api/attachments/abc-123"
    end

    test "the router serves exactly that path with Api.AttachmentController.show" do
      path = Schemas.Attachment.api_path(Ecto.UUID.generate())

      assert %{plug: HamacaWeb.Api.AttachmentController, plug_opts: :show} =
               Phoenix.Router.route_info(HamacaWeb.Router, "GET", path, "localhost")
    end
  end

  describe "attachment_url/1 and image_markdown/2 (RE428)" do
    test "the absolute url is the endpoint url plus the attachment path" do
      assert HamacaWeb.attachment_url("x") == HamacaWeb.Endpoint.url() <> "/attachments/x"
    end

    # RE480 scenario 8
    test "the absolute url's host is the configured endpoint host" do
      url = HamacaWeb.attachment_url("x")

      assert url == HamacaWeb.Endpoint.url() <> "/attachments/x"
      assert URI.parse(url).host == HamacaWeb.Endpoint.config(:url)[:host]
    end

    test "the markdown escapes the filename's brackets" do
      assert HamacaWeb.image_markdown("a[1].png", "http://h/attachments/x") == "![a\\[1\\].png](http://h/attachments/x)"
    end

    test "backslashes and closing parens are escaped too, as CardJSON always did" do
      assert HamacaWeb.image_markdown(~S"a\b).png", "/u") == ~S"![a\\b\).png](/u)"
    end
  end
end
