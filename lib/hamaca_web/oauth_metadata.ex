defmodule HamacaWeb.OAuthMetadata do
  @moduledoc """
  The URLs and discovery documents of Hamaca's OAuth 2.1 authorization server (RE519). Every
  URL is built from `HamacaWeb.Endpoint.url/0`, so the issuer, the endpoints and the protected
  `/mcp` resource always name the canonical host.

  `protected_resource/0` is the RFC 9728 document and `authorization_server/0` the RFC 8414
  document. `HamacaWeb.WellKnownController` serves both. Public clients only: PKCE S256, no
  client secret.
  """

  @doc "The authorization server's issuer: the endpoint's canonical URL."
  @spec issuer() :: String.t()
  def issuer, do: HamacaWeb.Endpoint.url()

  @doc "The protected MCP resource."
  @spec resource_url() :: String.t()
  def resource_url, do: issuer() <> "/mcp"

  @doc "Where a client finds `protected_resource/0` (the 401's `resource_metadata`)."
  @spec resource_metadata_url() :: String.t()
  def resource_metadata_url, do: issuer() <> "/.well-known/oauth-protected-resource"

  @doc "The RFC 9728 protected-resource metadata."
  @spec protected_resource() :: map()
  def protected_resource do
    %{resource: resource_url(), authorization_servers: [issuer()], bearer_methods_supported: ["header"]}
  end

  @doc "The RFC 8414 authorization-server metadata."
  @spec authorization_server() :: map()
  def authorization_server do
    %{
      issuer: issuer(),
      authorization_endpoint: issuer() <> "/oauth/authorize",
      token_endpoint: issuer() <> "/oauth/token",
      registration_endpoint: issuer() <> "/oauth/register",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"]
    }
  end
end
