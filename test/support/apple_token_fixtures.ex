defmodule Relay.AppleTokenFixtures do
  @moduledoc """
  RE106 test fixtures for Sign in with Apple: an RSA signing key, a `Req.Test` stub
  that serves its public half as Apple's JWKS, and RS256 identity tokens signed with it.
  Shared by the `Relay.Accounts.AppleTokenValidator` and `NativeAuthController` tests, so
  no real Apple contact happens in the suite. Boundary checks are off — test-only support.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  @key_cache {__MODULE__, :signing_key}

  @doc """
  An RSA-2048 key. Generated once per test run and cached in `:persistent_term` —
  RSA generation is slow. Use `new_signing_key/0` for a second, different key. The cache is
  write-once and every test gets the identical key, so it is not test-varying global state in
  ADR 0009's sense.
  """
  @spec signing_key() :: JOSE.JWK.t()
  def signing_key do
    case :persistent_term.get(@key_cache, nil) do
      nil ->
        key = new_signing_key()
        :persistent_term.put(@key_cache, key)
        key

      key ->
        key
    end
  end

  @doc "A freshly generated RSA-2048 key (uncached)."
  @spec new_signing_key() :: JOSE.JWK.t()
  def new_signing_key, do: JOSE.JWK.generate_key({:rsa, 2048})

  @doc "Stubs Apple's JWKS endpoint to serve `jwk`'s public half under `kid`."
  @spec stub_jwks(JOSE.JWK.t(), String.t()) :: :ok
  def stub_jwks(jwk, kid) do
    {_meta, public} = JOSE.JWK.to_public_map(jwk)
    keys = %{"keys" => [Map.merge(public, %{"kid" => kid, "alg" => "RS256", "use" => "sig"})]}

    Req.Test.stub(Relay.Accounts.AppleTokenValidator, fn conn -> Req.Test.json(conn, keys) end)
    :ok
  end

  @doc """
  An RS256-signed compact identity token with header `kid`. `overrides` replace the
  default claims; an override value of `:delete` drops that claim.
  """
  @spec apple_token(JOSE.JWK.t(), String.t(), map()) :: String.t()
  def apple_token(jwk, kid, overrides \\ %{}) do
    claims = claims(overrides)

    {_meta, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => kid}, claims)
      |> JOSE.JWS.compact()

    token
  end

  @doc "The default claims merged with `overrides` (`:delete` drops a claim)."
  @spec claims(map()) :: map()
  def claims(overrides \\ %{}) do
    defaults = %{
      "iss" => "https://appleid.apple.com",
      "aud" => "com.jeremylightsmith.Relay",
      "sub" => "apple-sub-1",
      "email" => "alice@example.com",
      "email_verified" => "true",
      "exp" => System.os_time(:second) + 600,
      "nonce" => sha256_hex("raw-nonce-1")
    }

    Enum.reduce(overrides, defaults, fn
      {key, :delete}, acc -> Map.delete(acc, to_string(key))
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
  end

  @doc "Lowercase hex SHA-256 of `raw` — the nonce the app hands Apple."
  @spec sha256_hex(String.t()) :: String.t()
  def sha256_hex(raw), do: :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)
end
