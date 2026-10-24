defmodule RelayWeb.PageController do
  @moduledoc """
  Public landing page. Signed-in users are sent straight to the board.

  A signed-out `/?code=RELAYCONF` (a promo sign-up link, RE462) stashes the code in the
  session as `:signup_promo_code` — trimmed, and dropped when blank or over
  64 bytes — for `RelayWeb.AuthController.callback/2` (or `/dev/login`) to redeem on
  sign-up. Only this action reads a `code` param: Google's OAuth callback carries its own.
  """

  use RelayWeb, :controller

  @max_code_bytes 64

  def home(conn, params) do
    if conn.assigns.current_scope do
      redirect(conn, to: ~p"/board")
    else
      conn
      |> put_signup_promo_code(params["code"])
      |> render(:home, page_title: "AI-first kanban board")
    end
  end

  defp put_signup_promo_code(conn, code) when is_binary(code) do
    case String.trim(code) do
      "" -> conn
      code when byte_size(code) > @max_code_bytes -> conn
      code -> put_session(conn, :signup_promo_code, code)
    end
  end

  defp put_signup_promo_code(conn, _code), do: conn

  def privacy(conn, _params), do: render(conn, :privacy, page_title: "Privacy Policy")

  def terms(conn, _params), do: render(conn, :terms, page_title: "Terms of Service")
end
