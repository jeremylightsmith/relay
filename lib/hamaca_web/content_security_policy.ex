defmodule HamacaWeb.ContentSecurityPolicy do
  @moduledoc """
  The one Content-Security-Policy string for browser pages. The router's `:browser` pipeline
  sends `header/0`.

  `header/1` widens `form-action` for a page whose form posts lead off-site. Browsers enforce
  `form-action` on the redirect that follows a form POST, so the OAuth consent page
  (`HamacaWeb.OAuthController`) must allow the client's redirect origin. Without it, Allow and
  Cancel would be silently blocked. It must also allow `google_sign_in_origin/0`: "Not you?"
  (and Allow / Cancel after the session expired) submit a form whose redirect chain runs
  through `/auth/google` to Google sign-in, and the browser checks `form-action` on every hop.
  Pass exact origins only, never `*`.
  """

  @google_sign_in_origin "https://accounts.google.com"

  @doc "The origin Google sign-in (`/auth/google`) redirects the browser to."
  @spec google_sign_in_origin() :: String.t()
  def google_sign_in_origin, do: @google_sign_in_origin

  @doc "The policy with `form-action 'self'` followed by each of `extra_form_action`'s origins."
  @spec header([String.t()]) :: String.t()
  def header(extra_form_action \\ []) when is_list(extra_form_action) do
    form_action = Enum.join(["'self'" | extra_form_action], " ")

    "default-src 'self'; " <>
      "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; " <>
      "style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' data: blob: https://*.googleusercontent.com; " <>
      "font-src 'self'; " <>
      "connect-src 'self' blob: ws: wss:; " <>
      "base-uri 'self'; " <>
      "form-action #{form_action}; " <>
      "frame-ancestors 'self';"
  end
end
