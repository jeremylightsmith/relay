defmodule Relay.Push.Delivery.APNS.JWT do
  @moduledoc """
  The APNs **provider token** (RLY-81 spec §7): an ES256 JWS over
  `{iss: <team id>, iat: <now>}` with `kid: <key id>` in the header, signed with
  the P-256 key from Apple's `.p8`.

  Apple permits reuse for up to an hour and rejects providers that re-sign on
  every push (`429 TooManyProviderTokenUpdates`), so one token is minted and
  reused for 40 minutes — comfortably inside Apple's window with room for clock
  skew. The cache lives in `:persistent_term`: written at most ~twice an hour and
  read on every push, which is exactly the tradeoff `:persistent_term` is for.
  """

  @key {__MODULE__, :token}
  @ttl_seconds 2400

  @doc """
  The current provider JWT for `config` (`[key:, key_id:, team_id:, …]`),
  minting a fresh one when the cache is empty or older than 40 minutes.
  """
  def fetch(config) do
    now = System.system_time(:second)

    case :persistent_term.get(@key, nil) do
      {jwt, minted_at} when now - minted_at < @ttl_seconds -> jwt
      _stale_or_missing -> mint(config, now)
    end
  end

  @doc "Drops the cached token — forces the next `fetch/1` to re-sign. Used by tests."
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  defp mint(config, now) do
    jwt = sign(config, now)
    :persistent_term.put(@key, {jwt, now})
    jwt
  end

  defp sign(config, now) do
    jwk = JOSE.JWK.from_pem(Keyword.fetch!(config, :key))
    jws = %{"alg" => "ES256", "kid" => Keyword.fetch!(config, :key_id)}
    claims = %{"iss" => Keyword.fetch!(config, :team_id), "iat" => now}

    {_meta, jwt} =
      jwk
      |> JOSE.JWT.sign(jws, claims)
      |> JOSE.JWS.compact()

    jwt
  end
end
