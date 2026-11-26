defmodule HamacaWeb.WellKnownControllerTest do
  use HamacaWeb.ConnCase, async: true

  describe "GET /.well-known/oauth-protected-resource (scenario 1)" do
    test "names /mcp as the resource and the endpoint as its authorization server", %{conn: conn} do
      body = conn |> get("/.well-known/oauth-protected-resource") |> json_response(200)

      assert body["resource"] == HamacaWeb.Endpoint.url() <> "/mcp"
      assert body["authorization_servers"] == [HamacaWeb.Endpoint.url()]
    end

    test "the RFC 9728 path-suffixed alias returns the same body", %{conn: conn} do
      plain = conn |> get("/.well-known/oauth-protected-resource") |> json_response(200)

      suffixed =
        build_conn() |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)

      assert suffixed == plain
    end
  end

  describe "GET /.well-known/oauth-authorization-server (scenario 2)" do
    test "advertises the OAuth endpoints and the PKCE-only public-client profile", %{conn: conn} do
      body = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)

      assert body["issuer"] == HamacaWeb.Endpoint.url()
      assert String.ends_with?(body["authorization_endpoint"], "/oauth/authorize")
      assert String.ends_with?(body["token_endpoint"], "/oauth/token")
      assert String.ends_with?(body["registration_endpoint"], "/oauth/register")
      assert body["code_challenge_methods_supported"] == ["S256"]
      assert body["grant_types_supported"] == ["authorization_code", "refresh_token"]
      assert body["token_endpoint_auth_methods_supported"] == ["none"]
      assert body["response_types_supported"] == ["code"]
    end
  end
end
