defmodule Relay.ApiKeys do
  @moduledoc """
  The ApiKeys context (MMF 08): a board's single API key.

  Raw tokens look like `relay_<prefix>_<secret>` (both parts hex, so the
  token splits unambiguously on `_`). The secret is returned exactly once
  from `create_key/2` / `regenerate/1` and stored only as a SHA-256 hash —
  fast and correct for high-entropy machine tokens (bcrypt is for
  passwords). `authenticate/1` is the entry point MMF 09's API auth will
  call: prefix lookup, then constant-time hash comparison.
  """

  use Boundary, deps: [Relay.Repo, Schemas]

  alias Relay.Repo
  alias Schemas.ApiKey
  alias Schemas.Board
  alias Schemas.User

  @default_name "Board API key"
  @prefix_bytes 6
  @secret_bytes 32
  @last_used_throttle_seconds 60

  @doc """
  Creates the board's API key. Returns `{:ok, %{api_key: key, token: raw}}` —
  the only place the raw token ever exists; it is never persisted or
  re-retrievable. Returns `{:error, :already_exists}` if the board already
  has a key (single-key invariant — the UI replaces keys via `regenerate/1`).
  """
  def create_key(%Board{} = board, %User{} = creator) do
    {prefix, secret, raw} = generate_token()

    changeset =
      ApiKey.changeset(%ApiKey{
        board_id: board.id,
        created_by_id: creator.id,
        name: @default_name,
        token_prefix: prefix,
        token_hash: hash_secret(secret),
        last_four: String.slice(secret, -4, 4)
      })

    case Repo.insert(changeset) do
      {:ok, key} -> {:ok, %{api_key: key, token: raw}}
      {:error, _changeset} -> {:error, :already_exists}
    end
  end

  @doc "Returns the board's API key, or nil when none exists."
  def get_key(%Board{id: board_id}), do: Repo.get_by(ApiKey, board_id: board_id)

  @doc """
  Replaces the key's secret in place (same row, new prefix + hash, cleared
  `last_used_at`) and returns `{:ok, %{api_key: key, token: raw}}` with the
  new raw token — revealed exactly once. The old token stops authenticating
  immediately.
  """
  def regenerate(%ApiKey{} = key) do
    {prefix, secret, raw} = generate_token()

    key =
      key
      |> Ecto.Changeset.change(
        token_prefix: prefix,
        token_hash: hash_secret(secret),
        last_four: String.slice(secret, -4, 4),
        last_used_at: nil
      )
      |> Repo.update!()

    {:ok, %{api_key: key, token: raw}}
  end

  @doc "Revokes (deletes) the key. Its token stops authenticating immediately."
  def revoke(%ApiKey{} = key), do: Repo.delete(key)

  @doc """
  Authenticates a raw `relay_<prefix>_<secret>` token: looks the key up by
  prefix, constant-time compares the secret's hash, bumps `last_used_at`
  (throttled to at most once per minute), and returns `{:ok, board}`. Any
  malformed, unknown, or revoked token returns `:error`. This is what MMF
  09's API authentication calls.
  """
  def authenticate(raw_token) when is_binary(raw_token) do
    with ["relay", prefix, secret] <- String.split(raw_token, "_", parts: 3),
         %ApiKey{} = key <- Repo.get_by(ApiKey, token_prefix: prefix),
         true <- Plug.Crypto.secure_compare(hash_secret(secret), key.token_hash) do
      touch_last_used(key)

      {:ok, Repo.preload(key, :board).board}
    else
      _not_authenticated -> :error
    end
  end

  # Throttle the last_used_at write so a once-per-minute poll (RLY-12) doesn't
  # write a row on every request. Only writes when never used or the stored
  # timestamp is older than the threshold, keeping the auth path near-free.
  defp touch_last_used(%ApiKey{last_used_at: last_used_at} = key) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    if stale?(last_used_at, now) do
      key
      |> Ecto.Changeset.change(last_used_at: now)
      |> Repo.update!()
    end
  end

  defp stale?(nil, _now), do: true

  defp stale?(last_used_at, now) do
    DateTime.diff(now, last_used_at, :second) >= @last_used_throttle_seconds
  end

  defp generate_token do
    prefix = random_hex(@prefix_bytes)
    secret = random_hex(@secret_bytes)
    {prefix, secret, "relay_#{prefix}_#{secret}"}
  end

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp hash_secret(secret), do: Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
end
