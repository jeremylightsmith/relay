defmodule RelayWeb.Api.AttachmentController do
  @moduledoc """
  `GET /api/attachments/:id` (RE373): an attachment's raw bytes for a REST API key, so a fresh
  agent session can read the mockups an earlier one uploaded (`./relay mockups REF --pull`).
  The browser twin is `RelayWeb.AttachmentController`; this one shares its content headers
  (`put_content_headers/2` — HTML still gets the sandbox CSP and nosniff) but is scoped to the
  key's board (`Relay.Attachments.get_attachment_for_board/2`) and answers every miss — unknown,
  malformed, another board's, missing bytes — with the same JSON 404, never 403. Served as a
  download (`Content-Disposition: attachment`) and cached `private`, because it is bearer-authed.
  """
  use RelayWeb, :controller

  alias Relay.Attachments
  alias RelayWeb.AttachmentController
  alias Schemas.Attachment

  action_fallback RelayWeb.Api.FallbackController

  # Same justification as RelayWeb.AttachmentController.show/2: `content_type` only ever comes
  # from `Schemas.Attachment.changeset/2`'s allow-list, and HTML is never served bare —
  # `put_content_headers/2` replaces the CSP with the sandbox policy and sets nosniff.
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  def show(conn, %{"id" => id}) do
    with %Attachment{} = attachment <- Attachments.get_attachment_for_board(conn.assigns.current_board, id),
         {:ok, bytes} <- Attachments.fetch_bytes(attachment) do
      conn
      |> AttachmentController.put_content_headers(attachment)
      |> put_resp_header("content-disposition", ~s|attachment; filename="#{safe_filename(attachment.filename)}"|)
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_resp(200, bytes)
    else
      _ -> {:error, :not_found}
    end
  end

  # The stored filename is caller-supplied: anything outside a conservative set becomes `_`, so
  # it can neither close the quoted value nor inject a header.
  defp safe_filename(filename), do: String.replace(filename, ~r/[^A-Za-z0-9._ -]/, "_")
end
