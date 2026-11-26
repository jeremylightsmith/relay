defmodule HamacaWeb.WellKnownController do
  @moduledoc """
  OAuth discovery for Claude clients (RE519, ADR 0015). It serves the RFC 9728
  protected-resource document (at its plain path and the path-suffixed `/mcp` alias) and the
  RFC 8414 authorization-server document. Both are public and unauthenticated, and both are
  built by `HamacaWeb.OAuthMetadata`.
  """

  use HamacaWeb, :controller

  alias HamacaWeb.OAuthMetadata

  def protected_resource(conn, _params), do: json(conn, OAuthMetadata.protected_resource())

  def authorization_server(conn, _params), do: json(conn, OAuthMetadata.authorization_server())
end
