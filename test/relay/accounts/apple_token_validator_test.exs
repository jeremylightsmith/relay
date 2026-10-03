defmodule Relay.Accounts.AppleTokenValidatorTest do
  # async: false — one case swaps the global `:apple_client_ids` env (restored on exit).
  use ExUnit.Case, async: false

  import Relay.AppleTokenFixtures

  alias Relay.Accounts.AppleTokenValidator

  # Rejection paths log on purpose; capture it (shown only on a failure).
  @moduletag :capture_log

  @kid "test-kid"
  @raw_nonce "raw-nonce-1"

  setup do
    key = signing_key()
    stub_jwks(key, @kid)
    %{key: key}
  end

  defp b64(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  test "returns normalized claims for a valid token", %{key: key} do
    token = apple_token(key, @kid)

    assert AppleTokenValidator.validate_token(token, @raw_nonce) ==
             {:ok,
              %{
                provider: "apple",
                provider_uid: "apple-sub-1",
                email: "alice@example.com",
                name: nil,
                avatar_url: nil
              }}
  end

  test "accepts a boolean email_verified", %{key: key} do
    token = apple_token(key, @kid, %{email_verified: true})
    assert {:ok, _claims} = AppleTokenValidator.validate_token(token, @raw_nonce)
  end

  test "rejects a token signed by a different key under the same kid" do
    token = apple_token(new_signing_key(), @kid)
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :invalid_token}
  end

  test "rejects a kid that is not in Apple's JWKS", %{key: key} do
    token = apple_token(key, "other-kid")
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :invalid_token}
  end

  test "rejects a malformed token without raising" do
    assert AppleTokenValidator.validate_token("not.a.jwt", @raw_nonce) == {:error, :invalid_token}
  end

  test "rejects an HS256 token even under a known kid" do
    {_meta, token} =
      "shared-secret"
      |> JOSE.JWK.from_oct()
      |> JOSE.JWT.sign(%{"alg" => "HS256", "kid" => @kid}, claims())
      |> JOSE.JWS.compact()

    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :invalid_token}
  end

  test "rejects an unsigned alg none token" do
    token = b64(%{"alg" => "none", "kid" => @kid}) <> "." <> b64(claims()) <> "."
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :invalid_token}
  end

  test "rejects a foreign issuer", %{key: key} do
    token = apple_token(key, @kid, %{iss: "https://evil.example.com"})
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :invalid_issuer}
  end

  test "rejects an audience outside the allowlist", %{key: key} do
    token = apple_token(key, @kid, %{aud: "com.attacker.App"})
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :invalid_audience}
  end

  test "rejects an expired token", %{key: key} do
    token = apple_token(key, @kid, %{exp: System.os_time(:second) - 60})
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :token_expired}
  end

  test "rejects a token whose nonce does not hash from the raw nonce", %{key: key} do
    token = apple_token(key, @kid)
    assert AppleTokenValidator.validate_token(token, "a-different-raw-nonce") == {:error, :invalid_nonce}
  end

  test "rejects a token with no nonce claim", %{key: key} do
    token = apple_token(key, @kid, %{nonce: :delete})
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :invalid_nonce}
  end

  test "rejects a token with no email", %{key: key} do
    token = apple_token(key, @kid, %{email: :delete})
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :email_missing}
  end

  test "rejects an unverified email", %{key: key} do
    token = apple_token(key, @kid, %{email_verified: "false"})
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :email_unverified}
  end

  test "maps a JWKS transport failure to :network_error", %{key: key} do
    Req.Test.stub(AppleTokenValidator, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    token = apple_token(key, @kid)
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :network_error}
  end

  test "maps a non-200 JWKS response to :network_error", %{key: key} do
    Req.Test.stub(AppleTokenValidator, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    token = apple_token(key, @kid)
    assert AppleTokenValidator.validate_token(token, @raw_nonce) == {:error, :network_error}
  end

  test "reads the audience allowlist from config", %{key: key} do
    original = Application.get_env(:relay, :apple_client_ids)
    on_exit(fn -> Application.put_env(:relay, :apple_client_ids, original) end)
    Application.put_env(:relay, :apple_client_ids, ["com.example.Other"])

    token = apple_token(key, @kid, %{aud: "com.example.Other"})
    assert {:ok, _claims} = AppleTokenValidator.validate_token(token, @raw_nonce)
  end
end
