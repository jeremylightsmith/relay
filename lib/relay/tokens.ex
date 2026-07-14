defmodule Relay.Tokens do
  @moduledoc """
  Shared bearer-token primitives for `Relay.ApiKeys` (board keys, `relay_…`) and
  `Relay.Accounts`' user tokens (`relayu_…`, RLY-80). Both mint a
  `<sentinel>_<prefix>_<secret>` raw token, hash only the secret (SHA-256) at
  rest, constant-time compare on auth, and throttle `last_used_at` writes.
  Centralizing this here means hardening the hash, adding a pepper, or
  changing the throttle window happens once for every token kind instead of
  drifting silently between two copies.
  """

  use Boundary, deps: [Relay.Repo]

  alias Relay.Repo

  @prefix_bytes 6
  @secret_bytes 32
  @last_used_throttle_seconds 60

  @doc """
  Generates a `{prefix, secret, raw}` triple for `sentinel` (e.g. `"relay"`,
  `"relayu"`). `raw` is `sentinel_prefix_secret` — the value returned to the
  caller exactly once and never persisted; only `hash/1` of the secret is
  stored.
  """
  def generate(sentinel) when is_binary(sentinel) do
    prefix = random_hex(@prefix_bytes)
    secret = random_hex(@secret_bytes)
    {prefix, secret, "#{sentinel}_#{prefix}_#{secret}"}
  end

  @doc "SHA-256 hashes a secret for storage at rest / constant-time comparison."
  def hash(secret) when is_binary(secret), do: Base.encode16(:crypto.hash(:sha256, secret), case: :lower)

  @doc """
  Splits a raw token into `{:ok, prefix, secret}` only when it starts with
  `sentinel`; otherwise `:error`. Keeps `relay_…` and `relayu_…` tokens
  mutually unparsable regardless of which context calls it.
  """
  def parse(raw_token, sentinel) when is_binary(raw_token) and is_binary(sentinel) do
    case String.split(raw_token, "_", parts: 3) do
      [^sentinel, prefix, secret] -> {:ok, prefix, secret}
      _other -> :error
    end
  end

  def parse(_raw_token, _sentinel), do: :error

  @doc """
  Bumps `record`'s `last_used_at` to now, throttled to at most once every
  #{@last_used_throttle_seconds}s so a polling client doesn't write a row per
  request. Returns `record` unchanged when the stored timestamp is still
  fresh, otherwise the updated record.
  """
  def touch_last_used(%{last_used_at: last_used_at} = record) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    if stale?(last_used_at, now) do
      record
      |> Ecto.Changeset.change(last_used_at: now)
      |> Repo.update!()
    else
      record
    end
  end

  defp stale?(nil, _now), do: true
  defp stale?(last_used_at, now), do: DateTime.diff(now, last_used_at, :second) >= @last_used_throttle_seconds

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
