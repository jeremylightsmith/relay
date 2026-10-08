defmodule Relay.Accounts.AppleTokenValidator do
  @moduledoc """
  Validates a Sign in with Apple identity token from native (iOS) sign-in and
  returns normalized provider claims for `Relay.Accounts.upsert_user_from_provider/2`.

  Unlike Google, Apple offers no tokeninfo endpoint: the RS256 token is verified
  locally with `:jose` against Apple's JWKS (`appleid.apple.com/auth/keys`), fetched
  with `Req` on every call (no cache). Only after the signature checks out are the
  claims trusted: `iss`, `aud` (the `:apple_client_ids` allowlist), `exp`, the nonce
  (the token's `nonce` must be the lowercase-hex SHA-256 of the raw nonce the app
  sends), and a verified email. Tests inject a `Req.Test` stub via
  `:apple_keys_req_options`, so no real Apple contact happens in the suite.

  Belongs to the `Relay.Accounts` boundary (no own `use Boundary`); it is
  exported from Accounts so `RelayWeb` may call it.
  """

  alias Relay.Accounts.GoogleTokenValidator

  require Logger

  @issuer "https://appleid.apple.com"
  @allowed_algs ["RS256"]

  @doc """
  Validates `identity_token` against `raw_nonce`. Returns `{:ok, claims}` with a
  `%{provider: "apple", provider_uid:, email:, name: nil, avatar_url: nil}` map, or
  `{:error, reason}` where reason is, in check order, one of `:network_error`,
  `:invalid_token`, `:invalid_issuer`, `:invalid_audience`, `:token_expired`,
  `:invalid_nonce`, `:email_missing`, `:email_unverified`.
  """
  @spec validate_token(String.t(), String.t()) ::
          {:ok, %{provider: String.t(), provider_uid: String.t(), email: String.t(), name: nil, avatar_url: nil}}
          | {:error, atom()}
  def validate_token(identity_token, raw_nonce) when is_binary(identity_token) and is_binary(raw_nonce) do
    with {:ok, keys} <- fetch_keys(),
         {:ok, claims} <- verify_signature(identity_token, keys),
         :ok <- verify_issuer(claims),
         :ok <- verify_audience(claims),
         :ok <- verify_expiry(claims),
         :ok <- verify_nonce(claims, raw_nonce),
         :ok <- verify_email(claims) do
      {:ok,
       %{
         provider: "apple",
         provider_uid: claims["sub"],
         email: claims["email"],
         name: nil,
         avatar_url: nil
       }}
    end
  end

  defp fetch_keys do
    case Req.get(req(), url: "/auth/keys") do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        {:ok, keys}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Apple JWKS fetch failed: #{status} #{inspect(body)}")
        {:error, :network_error}

      {:error, reason} ->
        Logger.error("Apple JWKS request error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  defp req do
    [base_url: @issuer, retry: false]
    |> Keyword.merge(Application.get_env(:relay, :apple_keys_req_options, []))
    |> Req.new()
  end

  # Picks the JWKS key by the header `kid`, then verifies with the algorithm pinned to
  # RS256 — `verify_strict/3`, so a token cannot choose `none` or HS256 for itself.
  defp verify_signature(token, keys) do
    with {:ok, kid} <- peek_kid(token),
         %{} = key <- Enum.find(keys, &(is_map(&1) and &1["kid"] == kid)),
         jwk = JOSE.JWK.from_map(key),
         {true, %JOSE.JWT{fields: claims}, _jws} <- JOSE.JWT.verify_strict(jwk, @allowed_algs, token) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  # `peek_protected/1` raises on malformed input; the rescue in `verify_signature/2` maps it.
  defp peek_kid(token) do
    case JOSE.JWT.peek_protected(token) do
      %JOSE.JWS{fields: %{"kid" => kid}} when is_binary(kid) -> {:ok, kid}
      _ -> {:error, :invalid_token}
    end
  end

  defp verify_issuer(%{"iss" => @issuer}), do: :ok
  defp verify_issuer(_claims), do: {:error, :invalid_issuer}

  defp verify_audience(%{"aud" => aud}) do
    if aud in Relay.Config.get(:apple_client_ids, []), do: :ok, else: {:error, :invalid_audience}
  end

  defp verify_audience(_claims), do: {:error, :invalid_audience}

  defp verify_expiry(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.os_time(:second), do: :ok, else: {:error, :token_expired}
  end

  defp verify_expiry(_claims), do: {:error, :token_expired}

  defp verify_nonce(%{"nonce" => nonce}, raw_nonce) when is_binary(nonce) do
    expected = :sha256 |> :crypto.hash(raw_nonce) |> Base.encode16(case: :lower)
    if Plug.Crypto.secure_compare(nonce, expected), do: :ok, else: {:error, :invalid_nonce}
  end

  defp verify_nonce(_claims, _raw_nonce), do: {:error, :invalid_nonce}

  defp verify_email(%{"email" => email} = claims) when is_binary(email) do
    if GoogleTokenValidator.email_verified?(claims), do: :ok, else: {:error, :email_unverified}
  end

  defp verify_email(_claims), do: {:error, :email_missing}
end
