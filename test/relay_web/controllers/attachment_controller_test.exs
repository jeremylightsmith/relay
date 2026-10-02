defmodule RelayWeb.AttachmentControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Attachments
  alias RelayWeb.AttachmentController

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

  test "an image keeps the app-wide CSP, not the mockup sandbox", %{
    conn: conn,
    attachment: attachment,
    member: member
  } do
    conn = conn |> log_in_user(member) |> get(~p"/attachments/#{attachment.id}")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    refute csp == AttachmentController.html_csp()
    refute csp =~ "sandbox"
    assert csp =~ "default-src 'self'"
    # RE372: the mockup-only no-referrer override never leaks onto images.
    refute get_resp_header(conn, "referrer-policy") == ["no-referrer"]
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

  describe "an HTML attachment (RE370)" do
    @html ~s|<!doctype html><p id="t">before</p><script>document.getElementById("t").textContent = "after"</script>|

    setup %{board: board} do
      card = insert(:card, stage: insert(:stage, board: board))

      {:ok, html} =
        Attachments.create_attachment(card, %{
          filename: "mock.html",
          content_type: Schemas.Attachment.html_type(),
          bytes: @html
        })

      {:ok, html: html}
    end

    test "is served as HTML under the sandbox CSP, replacing the app-wide one, with nosniff and no-referrer",
         %{conn: conn, html: html, member: member} do
      conn = conn |> log_in_user(member) |> get(~p"/attachments/#{html.id}")

      assert response(conn, 200) == @html
      assert conn |> get_resp_header("content-type") |> List.first() =~ Schemas.Attachment.html_type()
      assert get_resp_header(conn, "content-security-policy") == [AttachmentController.html_csp()]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      # RE372: Google Fonts requests must not carry Relay's host or the attachment path.
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end

    test "the policy runs scripts in an opaque origin with no network except Google Fonts, framable only by Relay" do
      csp = AttachmentController.html_csp()
      assert String.starts_with?(csp, "sandbox " <> RelayWeb.mockup_sandbox() <> ";")

      directives =
        csp
        |> String.split(";", trim: true)
        |> Map.new(fn directive ->
          [name | values] = directive |> String.trim() |> String.split(" ", trim: true)
          {name, values}
        end)

      style_origin = AttachmentController.google_fonts_style_origin()
      font_origin = AttachmentController.google_fonts_font_origin()

      assert style_origin == "https://fonts.googleapis.com"
      assert font_origin == "https://fonts.gstatic.com"

      assert "allow-scripts" in directives["sandbox"]

      for token <- ~w(allow-same-origin allow-top-navigation allow-popups allow-forms) do
        refute token in directives["sandbox"], "the mockup sandbox must not grant #{token}"
      end

      # The two widened directives (RE372) — exactly these sources, nothing more.
      assert directives["style-src"] == ["'unsafe-inline'", style_origin]
      assert directives["font-src"] == ["data:", font_origin]

      # Everything else stays closed — asserted, not assumed.
      assert directives["default-src"] == ["'none'"]
      assert directives["script-src"] == ["'unsafe-inline'"]
      assert directives["img-src"] == ["data:"]
      assert directives["form-action"] == ["'none'"]
      assert directives["frame-ancestors"] == ["'self'"]

      # These must fall back to default-src 'none' (fetch/XHR/WebSocket/EventSource/beacon,
      # remote media, nested frames, workers, plugins). Adding one is a deliberate test change.
      for absent <- ~w(connect-src media-src frame-src child-src worker-src object-src) do
        refute Map.has_key?(directives, absent), "#{absent} must not be declared"
      end

      # Each Google host is allowed only in its own directive.
      for {name, values} <- directives, name != "style-src" do
        refute style_origin in values, "#{style_origin} must appear only in style-src, found in #{name}"
      end

      for {name, values} <- directives, name != "font-src" do
        refute font_origin in values, "#{font_origin} must appear only in font-src, found in #{name}"
      end

      # No wildcard and no bare scheme source anywhere.
      for {name, values} <- directives, value <- values do
        refute String.contains?(value, "*"), "#{name} must not contain a wildcard: #{value}"
        refute value in ["https:", "http:"], "#{name} must not allow a bare scheme: #{value}"
        refute String.starts_with?(value, "http:"), "#{name} must not allow plain http: #{value}"
      end

      refute csp =~ "cdn.tailwindcss.com"
    end

    test "the served policy is exactly the RE372 string" do
      assert AttachmentController.html_csp() ==
               "sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; " <>
                 "style-src 'unsafe-inline' https://fonts.googleapis.com; img-src data:; " <>
                 "font-src data: https://fonts.gstatic.com; form-action 'none'; frame-ancestors 'self'"
    end

    test "a signed-in non-member gets 404", %{conn: conn, html: html} do
      conn = conn |> log_in_user() |> get(~p"/attachments/#{html.id}")
      assert response(conn, 404)
    end
  end
end
