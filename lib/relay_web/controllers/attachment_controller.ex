defmodule RelayWeb.AttachmentController do
  @moduledoc """
  Serves attachment bytes same-origin (RLY-13). Proxies the bytes from the storage adapter
  rather than redirecting to a presigned URL, so every attachment stays under the board's origin
  — no CSP widening, and the storage bucket stays hidden. Ids are stable and content never
  changes, so responses are cached long + immutable. Sits on the browser pipeline behind
  `:require_authenticated_user`, and — like every other board-scoped lookup — 404s unless
  `current_scope.user` is a member of the board that owns the attachment's card: same
  visibility as the board it belongs to.

  Two serving branches:

  - **Images** (png/jpeg/webp/gif) are served under the app-wide CSP, unchanged.
  - **HTML mockups** (RE370) are served under `html_csp/0`, which REPLACES the app-wide CSP for
    that response, plus `X-Content-Type-Options: nosniff`.

  ## Threat model for HTML (RE370)

  - **No `allow-same-origin`** → the document runs in an opaque origin: no `document.cookie`,
    no access to the parent frame. `_relay_key` is `SameSite=Lax`, so any request the sandbox
    could make is cross-site and carries no session.
  - **`default-src 'none'`** → no fetch/XHR/WebSocket/EventSource/beacon/remote images. Mockups
    must be fully self-contained (inline JS/CSS, `data:` assets).
  - **No `allow-top-navigation`, `allow-popups`, `allow-forms`**, and `form-action 'none'`.
  - **Residual risk: same-domain phishing** — a fake login rendered under Relay's host that
    exfiltrates typed input by navigating itself. Mitigated by never presenting a mockup as a
    bare top-level page from Relay's UI (the drawer and `/attachments/:id/view` always frame it
    under Relay chrome) and by `frame-ancestors 'self'`. A separate user-content origin is a
    documented follow-up, out of scope.
  - A busy-loop script only freezes its frame/tab — accepted.
  """
  use RelayWeb, :controller

  alias Relay.Attachments
  alias Schemas.Attachment

  @doc """
  The Content-Security-Policy an HTML attachment is served under (RE370). Its `sandbox` token
  list is `RelayWeb.mockup_sandbox/0` — the same value every mockup iframe's `sandbox`
  attribute carries.
  """
  def html_csp do
    "sandbox #{RelayWeb.mockup_sandbox()}; default-src 'none'; script-src 'unsafe-inline'; " <>
      "style-src 'unsafe-inline'; img-src data:; font-src data:; form-action 'none'; " <>
      "frame-ancestors 'self'"
  end

  # `attachment.content_type` and `bytes` are never taken verbatim from request input:
  # `content_type` is only ever persisted after `Schemas.Attachment.changeset/2` validates it
  # against the fixed allow-list (png/jpeg/webp/gif, and RE370's text/html); `bytes` are the
  # corresponding stored bytes. An image can never resolve to an HTML-interpretable content
  # type. HTML is the one deliberate exception and is never served bare: `put_content_headers/2`
  # gives it its own branch that replaces the app-wide CSP with `html_csp/0` (sandboxed opaque
  # origin, no network, framable only by Relay) and sets nosniff — see the moduledoc's threat
  # model.
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    with %Attachment{} = attachment <- Attachments.get_attachment(user, id),
         {:ok, bytes} <- Attachments.fetch_bytes(attachment) do
      conn
      |> put_content_headers(attachment)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  # The two serving branches. `content_type` comes from the validated allow-list (see show/2).
  # sobelow_skip ["XSS.ContentType"]
  defp put_content_headers(conn, %Attachment{} = attachment) do
    if Attachment.html?(attachment) do
      conn
      |> put_resp_content_type(attachment.content_type, "utf-8")
      |> put_resp_header("content-security-policy", html_csp())
      |> put_resp_header("x-content-type-options", "nosniff")
    else
      put_resp_content_type(conn, attachment.content_type, nil)
    end
  end
end
