defmodule RelayWeb.ApiUserAuth do
  @moduledoc """
  Authenticates the `/api/all` scope by `Authorization: Bearer <user token>` (RLY-80) —
  the native app's decision surfaces, acting as the signed-in human. On success assigns
  `:current_user` and the `{:user, id}` actor; otherwise responds 401 JSON and halts.

  Bearer, not the session cookie: stateless, no ambient credential, no CSRF surface.
  The sibling `RelayWeb.ApiAuth` authenticates the agent-only board-key `/api` scope;
  the two token formats (`relayu_…` vs `relay_…`) are mutually unauthenticable.
  """

  import Plug.Conn

  alias Relay.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Accounts.authenticate_user_api_token(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:actor, {:user, user.id})
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    body = Jason.encode!(%{error: %{code: "unauthorized", message: "Invalid or missing user token"}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
