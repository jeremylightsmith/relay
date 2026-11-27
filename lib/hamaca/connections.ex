defmodule Hamaca.Connections do
  @moduledoc """
  The Connections context (RE519): how a Claude client (claude.ai, Desktop, mobile, Claude
  Code) connects to Hamaca over OAuth 2.1 and then acts as the signed-in user.

  It owns dynamically registered clients (`Schemas.OAuthClient`), the user × client grant
  (`Schemas.OAuthGrant`), single-use PKCE authorization codes (`Schemas.OAuthCode`) and
  hashed access/refresh tokens (`Schemas.OAuthToken`). Raw codes and tokens exist only in
  the return value of the call that minted them; only SHA-256 hashes are stored. Tokens are
  `relaym_<prefix>_<secret>` — the `relaym` sentinel (`token_sentinel/0`) keeps them apart
  from user tokens (`relayu_…`, `Hamaca.Accounts`) and board keys (`relay_…`,
  `Hamaca.ApiKeys`).

  It also owns the policy numbers (token and code TTLs, registration caps) and the one fixed
  list of what a connection can and can't do (`capabilities/1`).
  """

  use Boundary, deps: [Hamaca.Accounts, Hamaca.Repo, Schemas], exports: []

  import Ecto.Query

  alias Hamaca.Accounts
  alias Hamaca.Repo
  alias Schemas.OAuthClient
  alias Schemas.OAuthCode
  alias Schemas.OAuthGrant
  alias Schemas.OAuthToken
  alias Schemas.User

  @access_token_ttl_seconds 3600
  @refresh_token_ttl_seconds 2_592_000
  @code_ttl_seconds 60
  @registration_limits %{max_redirect_uris: 10, max_client_name_length: 200, max_redirect_uri_length: 2000}
  @token_sentinel "relaym"
  @token_prefix_bytes 6
  @token_secret_bytes 32
  @client_id_bytes 16
  @code_bytes 32
  @loopback_hosts ["localhost", "127.0.0.1"]
  @code_verifier_format ~r/\A[A-Za-z0-9\-._~]{43,128}\z/

  @type token_response :: %{
          access_token: String.t(),
          token_type: String.t(),
          expires_in: pos_integer(),
          refresh_token: String.t()
        }

  @doc "Lifetime of an access token, in seconds."
  @spec access_token_ttl_seconds() :: pos_integer()
  def access_token_ttl_seconds, do: @access_token_ttl_seconds

  @doc "Lifetime of a refresh token, in seconds (30 days)."
  @spec refresh_token_ttl_seconds() :: pos_integer()
  def refresh_token_ttl_seconds, do: @refresh_token_ttl_seconds

  @doc "Lifetime of an authorization code, in seconds."
  @spec code_ttl_seconds() :: pos_integer()
  def code_ttl_seconds, do: @code_ttl_seconds

  @doc "The payload caps on dynamic client registration (there is no per-IP rate limiter)."
  @spec registration_limits() :: %{
          max_redirect_uris: pos_integer(),
          max_client_name_length: pos_integer(),
          max_redirect_uri_length: pos_integer()
        }
  def registration_limits, do: @registration_limits

  @doc "The first segment of every raw access/refresh token: `relaym_<prefix>_<secret>`."
  @spec token_sentinel() :: String.t()
  def token_sentinel, do: @token_sentinel

  @doc """
  Registers a client from string-keyed params: `"redirect_uris"` (required, a non-empty list
  of `https://` or loopback `http://localhost|127.0.0.1` URIs without a fragment) and
  `"client_name"` (optional). A bad URI is `:invalid_redirect_uri`; any other bad metadata
  (missing/empty/oversized list, a too-long or non-string name) is `:invalid_client_metadata`.
  """
  @spec register_client(map()) :: {:ok, OAuthClient.t()} | {:error, :invalid_redirect_uri | :invalid_client_metadata}
  def register_client(params) when is_map(params) do
    with {:ok, client_name} <- validate_client_name(Map.get(params, "client_name")),
         {:ok, redirect_uris} <- validate_redirect_uris(Map.get(params, "redirect_uris")) do
      %OAuthClient{
        client_id: random_url_safe(@client_id_bytes),
        client_name: client_name,
        redirect_uris: redirect_uris
      }
      |> OAuthClient.changeset()
      |> Repo.insert()
    end
  end

  def register_client(_params), do: {:error, :invalid_client_metadata}

  @doc "Fetches a client by its public `client_id`, or nil."
  @spec get_client(String.t()) :: OAuthClient.t() | nil
  def get_client(client_id) when is_binary(client_id), do: Repo.get_by(OAuthClient, client_id: client_id)

  @doc "Whether `redirect_uri` is one of the client's registered URIs — an exact string match."
  @spec redirect_uri_registered?(OAuthClient.t(), String.t()) :: boolean()
  def redirect_uri_registered?(%OAuthClient{redirect_uris: uris}, redirect_uri), do: redirect_uri in uris

  @doc """
  Records `user`'s approval of `client` and issues a single-use authorization code. The
  user × client grant is upserted (a new or revoked grant gets a fresh `connected_at` and a
  cleared `revoked_at`; a live one is left as it is). Returns the raw code; only its SHA-256
  is stored.
  """
  @spec authorize(User.t(), OAuthClient.t(), %{
          redirect_uri: String.t(),
          code_challenge: String.t(),
          resource: String.t() | nil
        }) :: {:ok, String.t()}
  def authorize(%User{} = user, %OAuthClient{} = client, %{redirect_uri: redirect_uri, code_challenge: challenge} = req) do
    now = now()
    raw_code = random_url_safe(@code_bytes)

    Repo.transact(fn ->
      grant = upsert_grant!(user, client, now)

      %OAuthCode{
        grant_id: grant.id,
        code_hash: sha256_hex(raw_code),
        code_challenge: challenge,
        redirect_uri: redirect_uri,
        resource: Map.get(req, :resource),
        expires_at: DateTime.add(now, @code_ttl_seconds, :second)
      }
      |> OAuthCode.changeset()
      |> Repo.insert!()

      {:ok, raw_code}
    end)
  end

  # One statement, so two concurrent approvals can't both insert: on conflict a revoked grant
  # is reconnected (Postgres evaluates every SET against the old row, so the CASE still sees
  # the pre-update revoked_at) and a live one keeps its connected_at.
  defp upsert_grant!(user, client, now) do
    reconnect =
      from(g in OAuthGrant,
        update: [
          set: [
            connected_at:
              fragment("CASE WHEN ? IS NULL THEN ? ELSE EXCLUDED.connected_at END", g.revoked_at, g.connected_at),
            revoked_at: nil,
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]
      )

    %OAuthGrant{user_id: user.id, oauth_client_id: client.id, connected_at: now}
    |> OAuthGrant.changeset()
    |> Repo.insert!(on_conflict: reconnect, conflict_target: [:user_id, :oauth_client_id], returning: true)
  end

  @doc """
  Exchanges an authorization code (string-keyed `"code"`, `"redirect_uri"`, `"client_id"`,
  `"code_verifier"`, optional `"resource"`) for an access + refresh token pair. A missing or
  non-string param is `:invalid_request`, an unknown client `:invalid_client`, and any
  mismatch, expiry, bad verifier or revoked grant `:invalid_grant`. A code presented a second
  time is `:invalid_grant` and revokes every token of its grant.
  """
  @spec exchange_code(map()) :: {:ok, token_response()} | {:error, :invalid_grant | :invalid_client | :invalid_request}
  def exchange_code(params) when is_map(params) do
    with {:ok, [code, redirect_uri, client_id, verifier]} <-
           fetch_strings(params, ["code", "redirect_uri", "client_id", "code_verifier"]),
         {:ok, resource} <- fetch_optional_string(params, "resource"),
         {:ok, client} <- fetch_client(client_id) do
      request = %{redirect_uri: redirect_uri, verifier: verifier, resource: resource}

      unwrap_transaction(fn -> redeem_code(sha256_hex(code), client, request) end)
    end
  end

  def exchange_code(_params), do: {:error, :invalid_request}

  defp redeem_code(code_hash, client, request) do
    now = now()

    code =
      Repo.one(
        from(c in OAuthCode,
          join: g in assoc(c, :grant),
          where: c.code_hash == ^code_hash,
          preload: [grant: g]
        )
      )

    cond do
      is_nil(code) or code.grant.oauth_client_id != client.id -> {:error, :invalid_grant}
      not is_nil(code.used_at) -> replayed(code.grant)
      not code_redeemable?(code, request, now) -> {:error, :invalid_grant}
      true -> mark_used_and_mint(code, now)
    end
  end

  defp code_redeemable?(code, request, now) do
    is_nil(code.grant.revoked_at) and
      future?(code.expires_at, now) and
      code.redirect_uri == request.redirect_uri and
      (is_nil(request.resource) or request.resource == code.resource) and
      verifier_matches?(request.verifier, code.code_challenge)
  end

  defp verifier_matches?(verifier, challenge) do
    Regex.match?(@code_verifier_format, verifier) and
      Plug.Crypto.secure_compare(Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false), challenge)
  end

  # The conditional update is the single-use guard: a concurrent exchange of the same code
  # blocks on the row lock, then matches 0 rows and is treated as the replay it is.
  defp mark_used_and_mint(code, now) do
    case Repo.update_all(from(c in OAuthCode, where: c.id == ^code.id and is_nil(c.used_at)), set: [used_at: now]) do
      {1, _} -> {:ok, mint_token_pair!(code.grant, now)}
      {0, _} -> replayed(code.grant)
    end
  end

  # RFC 6749 §4.1.2: a code used twice revokes the tokens issued from it. This runs inside a
  # committing transaction — the deletion must stick even though the caller gets an error.
  defp replayed(grant) do
    delete_grant_tokens(grant)
    {:error, :invalid_grant}
  end

  @doc """
  Rotates a refresh token (string-keyed `"refresh_token"`, `"client_id"`): the presented
  token is deleted and a fresh access + refresh pair is returned. An unknown client is
  `:invalid_client`; an unknown, access-kind, expired, foreign or revoked token, or one whose
  user is deleted or suspended (RE510), is `:invalid_grant`.
  """
  @spec refresh(map()) :: {:ok, token_response()} | {:error, :invalid_grant | :invalid_client | :invalid_request}
  def refresh(params) when is_map(params) do
    with {:ok, [raw_token, client_id]} <- fetch_strings(params, ["refresh_token", "client_id"]),
         {:ok, client} <- fetch_client(client_id) do
      unwrap_transaction(fn -> rotate_refresh_token(raw_token, client) end)
    end
  end

  def refresh(_params), do: {:error, :invalid_request}

  defp rotate_refresh_token(raw_token, client) do
    now = now()

    with {:ok, %OAuthToken{kind: :refresh} = token} <- verify_token(raw_token, now),
         true <- token.grant.oauth_client_id == client.id,
         {1, _} <- Repo.delete_all(from(t in OAuthToken, where: t.id == ^token.id)) do
      {:ok, mint_token_pair!(token.grant, now)}
    else
      _invalid -> {:error, :invalid_grant}
    end
  end

  @doc """
  Authenticates a raw `relaym_<prefix>_<secret>` access token: prefix lookup, constant-time
  hash compare, then `kind == :access`, unexpired, a live grant, and a user who is neither
  deleted nor suspended (RE510; the token works again once the suspension is undone). Bumps the grant's
  `last_used_at` (throttled by `Hamaca.Accounts.last_used_throttle_seconds/0`). Anything
  else — including `relayu_…` user tokens, `relay_…` board keys and non-binaries — is
  `:error`.
  """
  @spec authenticate_access_token(term()) :: {:ok, User.t(), OAuthGrant.t()} | :error
  def authenticate_access_token(raw_token) when is_binary(raw_token) do
    now = now()

    case verify_token(raw_token, now) do
      {:ok, %OAuthToken{kind: :access, grant: grant}} ->
        grant = touch_last_used(grant, now)
        {:ok, grant.user, grant}

      _not_authenticated ->
        :error
    end
  end

  def authenticate_access_token(_raw_token), do: :error

  # The checks every presented token must pass regardless of kind: shape, a known prefix, the
  # constant-time hash compare, not expired, a grant that hasn't been revoked, and a user who
  # isn't a deleted account's tombstone (RE509) or suspended (RE510). Suspension is checked at
  # read time and revokes nothing, so undoing it restores the same grant.
  defp verify_token(raw_token, now) do
    with [@token_sentinel, prefix, secret] <- String.split(raw_token, "_", parts: 3),
         %OAuthToken{} = token <- get_token_by_prefix(prefix),
         true <- Plug.Crypto.secure_compare(sha256_hex(secret), token.token_hash),
         true <- future?(token.expires_at, now),
         nil <- token.grant.revoked_at,
         false <- User.suspended?(token.grant.user) do
      {:ok, token}
    else
      _invalid -> :error
    end
  end

  defp get_token_by_prefix(prefix) do
    Repo.one(
      from(t in OAuthToken,
        join: g in assoc(t, :grant),
        join: u in assoc(g, :user),
        where: t.token_prefix == ^prefix and is_nil(u.deleted_at),
        preload: [grant: {g, user: u}]
      )
    )
  end

  defp touch_last_used(%OAuthGrant{last_used_at: last_used_at} = grant, now) do
    if is_nil(last_used_at) or DateTime.diff(now, last_used_at, :second) >= Accounts.last_used_throttle_seconds() do
      grant |> Ecto.Changeset.change(last_used_at: now) |> Repo.update!()
    else
      grant
    end
  end

  @doc "The user's live (non-revoked) grants, `:oauth_client` preloaded, newest `connected_at` first."
  @spec list_grants(User.t()) :: [OAuthGrant.t()]
  def list_grants(%User{} = user) do
    Repo.all(
      from(g in OAuthGrant,
        where: g.user_id == ^user.id and is_nil(g.revoked_at),
        order_by: [desc: g.connected_at, desc: g.id],
        preload: :oauth_client
      )
    )
  end

  @doc """
  Disconnects one of `user`'s grants: stamps `revoked_at` and deletes its tokens and codes. A
  grant that isn't the user's is `{:error, :not_found}`.
  """
  @spec revoke_grant(User.t(), integer()) :: :ok | {:error, :not_found}
  def revoke_grant(%User{} = user, grant_id) when is_integer(grant_id) do
    unwrap_transaction(fn ->
      case Repo.get_by(OAuthGrant, id: grant_id, user_id: user.id) do
        nil ->
          {:error, :not_found}

        grant ->
          grant |> Ecto.Changeset.change(revoked_at: grant.revoked_at || now()) |> Repo.update!()
          delete_grant_tokens(grant)
          Repo.delete_all(from(c in OAuthCode, where: c.grant_id == ^grant.id))
          :ok
      end
    end)
  end

  @doc """
  What a connection can and can't do — the ONE definition of the consent bullets, rendered by
  the consent screen and the Connections page. `board_count` phrases the read bullet.
  """
  @spec capabilities(non_neg_integer()) :: %{
          can: [%{icon: String.t(), title: String.t(), detail: String.t()}],
          cannot: String.t()
        }
  def capabilities(board_count) when is_integer(board_count) and board_count >= 0 do
    %{
      can: [
        %{
          icon: "hero-eye",
          title: read_boards_title(board_count),
          detail: ": cards, comments and who has the baton. Boards you join later are included too."
        }
      ],
      cannot: "Claude can't approve, reject, answer questions or move cards. Those stay with you in Hamaca."
    }
  end

  defp read_boards_title(0), do: "Read your boards"
  defp read_boards_title(1), do: "Read your 1 board"
  defp read_boards_title(n), do: "Read all #{n} of your boards"

  # ── registration validation ────────────────────────────────────────────────

  defp validate_client_name(nil), do: {:ok, nil}

  defp validate_client_name(name) when is_binary(name) do
    if String.length(name) <= @registration_limits.max_client_name_length,
      do: {:ok, name},
      else: {:error, :invalid_client_metadata}
  end

  defp validate_client_name(_name), do: {:error, :invalid_client_metadata}

  defp validate_redirect_uris([_ | _] = uris) do
    cond do
      length(uris) > @registration_limits.max_redirect_uris -> {:error, :invalid_client_metadata}
      not Enum.all?(uris, &is_binary/1) -> {:error, :invalid_client_metadata}
      not Enum.all?(uris, &valid_redirect_uri?/1) -> {:error, :invalid_redirect_uri}
      true -> {:ok, uris}
    end
  end

  defp validate_redirect_uris(_uris), do: {:error, :invalid_client_metadata}

  defp valid_redirect_uri?(uri) do
    byte_size(uri) <= @registration_limits.max_redirect_uri_length and
      case URI.new(uri) do
        {:ok, %URI{fragment: nil, scheme: "https", host: host}} when is_binary(host) and host != "" -> true
        {:ok, %URI{fragment: nil, scheme: "http", host: host}} when host in @loopback_hosts -> true
        _other -> false
      end
  end

  # ── token minting ──────────────────────────────────────────────────────────

  defp mint_token_pair!(%OAuthGrant{} = grant, now) do
    Repo.delete_all(from(t in OAuthToken, where: t.grant_id == ^grant.id and t.expires_at <= ^now))

    %{
      access_token: insert_token!(grant, :access, DateTime.add(now, @access_token_ttl_seconds, :second)),
      token_type: "Bearer",
      expires_in: @access_token_ttl_seconds,
      refresh_token: insert_token!(grant, :refresh, DateTime.add(now, @refresh_token_ttl_seconds, :second))
    }
  end

  # Mirrors Hamaca.Accounts.create_user_api_token/2: the prefix and the secret's hash are
  # stored; the raw token is returned once and never persisted.
  defp insert_token!(grant, kind, expires_at) do
    prefix = random_hex(@token_prefix_bytes)
    secret = random_hex(@token_secret_bytes)

    %OAuthToken{
      grant_id: grant.id,
      kind: kind,
      token_prefix: prefix,
      token_hash: sha256_hex(secret),
      expires_at: expires_at
    }
    |> OAuthToken.changeset()
    |> Repo.insert!()

    "#{@token_sentinel}_#{prefix}_#{secret}"
  end

  defp delete_grant_tokens(%OAuthGrant{id: grant_id}) do
    Repo.delete_all(from(t in OAuthToken, where: t.grant_id == ^grant_id))
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Runs `fun` in a transaction that COMMITS whatever it returns — error results included
  # (a replayed code's token revocation must persist) — and hands back that result.
  # Anything raised still rolls back.
  defp unwrap_transaction(fun) do
    {:ok, result} = Repo.transact(fn -> {:ok, fun.()} end)
    result
  end

  defp fetch_strings(params, keys) do
    values = Enum.map(keys, &Map.get(params, &1))

    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: {:error, :invalid_request}
  end

  defp fetch_optional_string(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, :invalid_request}
    end
  end

  defp fetch_client(client_id) do
    case get_client(client_id) do
      %OAuthClient{} = client -> {:ok, client}
      nil -> {:error, :invalid_client}
    end
  end

  defp future?(%DateTime{} = at, now), do: DateTime.after?(at, now)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp random_url_safe(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp sha256_hex(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end
