defmodule HamacaWeb.McpAuth do
  @moduledoc """
  Authenticates `/mcp` (RE519, ADR 0015) by `Authorization: Bearer relaym_…` — an OAuth access
  token minted by `Hamaca.Connections`. On success assigns `:current_user`, the `{:user, id}`
  actor and `:oauth_grant`: the MCP server acts as the signed-in human, never as the agent.

  A request carrying an `Origin` other than the server's own is refused 403 before any token is
  looked at (the MCP transport's DNS-rebinding guard). Anything unauthenticated is 401 with the
  RFC 9728 `WWW-Authenticate: Bearer resource_metadata="…"` challenge that starts a Claude
  client's OAuth sign-in; a presented-but-rejected token adds `error="invalid_token"`.

  The sibling `HamacaWeb.ApiUserAuth` (`relayu_…`) and `HamacaWeb.ApiAuth` (`relay_…`) tokens
  never authenticate here.
  """

  import Plug.Conn

  alias Hamaca.Connections
  alias HamacaWeb.OAuthMetadata

  def init(opts), do: opts

  def call(conn, _opts) do
    if foreign_origin?(conn) do
      conn |> send_json(403, %{error: "forbidden_origin"}) |> halt()
    else
      authenticate(conn)
    end
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Connections.authenticate_access_token(token) do
          {:ok, user, grant} ->
            conn
            |> assign(:current_user, user)
            |> assign(:actor, {:user, user.id})
            |> assign(:oauth_grant, grant)

          :error ->
            unauthorized(conn, ~s(, error="invalid_token"))
        end

      _no_bearer ->
        unauthorized(conn, "")
    end
  end

  defp unauthorized(conn, error) do
    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Bearer resource_metadata="#{OAuthMetadata.resource_metadata_url()}") <> error
    )
    |> send_json(401, %{error: "unauthorized"})
    |> halt()
  end

  defp foreign_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] -> false
      [origin | _] -> origin(origin) != origin(OAuthMetadata.issuer())
    end
  end

  # scheme://host:port with the default port made explicit, so `https://h` and `https://h:443`
  # are the same origin. Anything unparseable is nil and never equals the issuer's.
  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        "#{String.downcase(scheme)}://#{String.downcase(host)}:#{port}"

      _unparseable ->
        nil
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
