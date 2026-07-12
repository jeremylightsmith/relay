defmodule RelayWeb.AttachmentController do
  @moduledoc """
  Serves attachment image bytes same-origin (RLY-13). Proxies the bytes from
  the storage adapter rather than redirecting to a presigned URL, so every
  image stays under the board's origin and the CSP `img-src 'self'` — no CSP
  widening, and the storage bucket stays hidden. Ids are stable and content
  never changes, so responses are cached long + immutable. Sits on the
  browser pipeline behind `:require_authenticated_user`: same visibility as
  the board it belongs to.
  """
  use RelayWeb, :controller

  alias Relay.Attachments

  # `attachment.content_type` and `bytes` are never taken verbatim from
  # request input: `content_type` is only ever persisted after
  # `Schemas.Attachment.changeset/2` validates it against the fixed image
  # allow-list (png/jpeg/webp/gif), so it can never resolve to an
  # HTML-interpretable content type; `bytes` are the corresponding stored
  # image bytes.
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  def show(conn, %{"id" => id}) do
    with %Schemas.Attachment{} = attachment <- Attachments.get_attachment(id),
         {:ok, bytes} <- Attachments.fetch_bytes(attachment) do
      conn
      |> put_resp_content_type(attachment.content_type, nil)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
