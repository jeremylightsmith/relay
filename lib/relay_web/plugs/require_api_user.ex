defmodule RelayWeb.Plugs.RequireApiUser do
  @moduledoc """
  Requires a signed-in **user** on the native JSON API (`/api/all`) — the routes
  the Flutter shell calls directly rather than through its embedded webview.

  Auth is the session cookie F2's native sign-in (`RelayWeb.NativeAuthController`)
  writes and dio's cookie jar persists, so no new credential is needed. Unlike
  `RelayWeb.Auth.require_authenticated/2` this halts with a 401 JSON body rather
  than a browser redirect, and unlike `RelayWeb.ApiAuth` it yields a *user*
  (that pipeline authenticates a *board* by API key and assigns the `:agent`
  actor).

  Sits after `RelayWeb.Auth.fetch_current_scope/2`, which assigns `:current_scope`.
  RLY-80 (F4) extends this same scope with a user-scoped bearer token.
  """

  import Plug.Conn

  alias Schemas.Scope
  alias Schemas.User

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: %User{}} ->
        conn

      _ ->
        body = Jason.encode!(%{error: %{code: "unauthorized", message: "Sign-in required"}})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, body)
        |> halt()
    end
  end
end
