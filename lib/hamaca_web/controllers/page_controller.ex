defmodule HamacaWeb.PageController do
  @moduledoc """
  Public landing page. Signed-in users are sent straight to the board.

  A signed-out `/?code=RELAYCONF` (a promo sign-up link, RE462) stashes the code in the
  session as `:signup_promo_code` — trimmed, and dropped when blank or over
  64 bytes — for `HamacaWeb.AuthController.callback/2` (or `/dev/login`) to redeem on
  sign-up. Only this action reads a `code` param: Google's OAuth callback carries its own.
  """

  use HamacaWeb, :controller

  @max_code_bytes 64

  # The landing page's one meta description (RE476) — ≤155 chars so search results show it whole.
  @meta_description "Hamaca turns your AI agents into a factory you can see at a glance. Your phone lights up only when a decision is yours."

  def home(conn, params) do
    if conn.assigns.current_scope do
      redirect(conn, to: ~p"/board")
    else
      conn
      |> put_signup_promo_code(params["code"])
      |> render(:home,
        page_title: "Hammock Driven Development",
        meta: %{
          title: "Hamaca: Hammock Driven Development",
          description: @meta_description,
          url: url(~p"/"),
          image: url(~p"/images/og-image.png")
        }
      )
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
