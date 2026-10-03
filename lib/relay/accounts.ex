defmodule Relay.Accounts do
  @moduledoc """
  The Accounts context: users, the current-user scope, and user-scoped API tokens.

  Google (web OAuth + native) and Apple (native) are the real sign-in paths
  (open signup). Every provider funnels through `upsert_user_from_provider/2`,
  which links sign-ins by `provider_uid` first, then by verified email, so one
  person using both Google and Apple keeps one account. `ensure_dev_user!/0` backs the dev/test-only
  login bypass. Web/session concerns live in `RelayWeb.Auth`, not here.
  `create_user_api_token/2` and `authenticate_user_api_token/1` mint and verify
  the bearer tokens the native app uses for its JSON calls.
  """

  use Boundary, deps: [Relay.Repo, Schemas], exports: [GoogleTokenValidator]

  import Ecto.Query

  alias Relay.Accounts.GoogleTokenValidator
  alias Relay.Repo
  alias Schemas.Membership
  alias Schemas.User
  alias Schemas.UserApiToken

  @dev_user_email "dev@relay.local"
  @dev_user_uid "dev-user"
  @user_token_prefix_bytes 6
  @user_token_secret_bytes 32
  @user_token_last_used_throttle_seconds 60
  @default_user_token_context "mobile"

  @doc "Fetches a user by primary key. Returns nil when not found."
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Every user for the superadmin `/admin/users` table (RE353), newest first
  (`inserted_at desc, id desc`), with `board_count` = the user's membership rows. Unscoped on
  purpose: the gate is the `/admin` route (`RelayWeb.Auth.require_superadmin`), not this
  context. One query (aggregate subquery, no N+1).
  """
  def list_users_for_admin do
    board_counts =
      from m in Membership,
        where: not is_nil(m.user_id),
        group_by: m.user_id,
        select: %{user_id: m.user_id, n: count(m.id)}

    Repo.all(
      from u in User,
        left_join: bc in subquery(board_counts),
        on: bc.user_id == u.id,
        order_by: [desc: u.inserted_at, desc: u.id],
        select: %{
          id: u.id,
          name: u.name,
          email: u.email,
          provider: u.provider,
          inserted_at: u.inserted_at,
          board_count: coalesce(bc.n, 0)
        }
    )
  end

  @doc """
  Upserts a user from normalized provider claims (the provider-agnostic seam).
  Every sign-in path (Google web + native, Apple native) flows through here.

  `claims` carries `:provider`, `:provider_uid`, `:email`, `:name` and
  `:avatar_url`; the email must already be verified by the caller. Lookup order:

    1. a `provider_uid` match returns that user, refreshing its profile from the
       non-nil `:email` / `:name` / `:avatar_url` claims;
    2. otherwise a match on the normalized email (`User.normalize_email/1`) signs
       in that existing user, keeping its `provider` / `provider_uid` and
       refreshing only non-nil `:name` / `:avatar_url`;
    3. otherwise a new `%User{provider:, provider_uid:}` is inserted.

  A nil claim never wipes a stored value. `opts[:name]` is a fallback display
  name used only when inserting and only when `claims.name` is nil.

  Returns `{:error, changeset}` when a `provider_uid` match's new email belongs
  to another user.
  """
  @spec upsert_user_from_provider(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def upsert_user_from_provider(%{provider: provider, provider_uid: provider_uid} = claims, opts \\ []) do
    case find_existing(claims) do
      {:provider_uid, user} ->
        refresh_profile(user, claims, [:email, :name, :avatar_url])

      {:email, user} ->
        refresh_profile(user, claims, [:name, :avatar_url])

      nil ->
        profile = Map.take(claims, [:email, :name, :avatar_url])
        profile = if profile[:name], do: profile, else: Map.put(profile, :name, opts[:name])

        %User{provider: provider, provider_uid: provider_uid}
        |> User.changeset(profile)
        |> Repo.insert()
    end
  end

  # Lookup steps 1 and 2: provider_uid (unscoped by provider on purpose), then normalized email.
  defp find_existing(%{provider_uid: provider_uid} = claims) do
    cond do
      user = Repo.get_by(User, provider_uid: provider_uid) -> {:provider_uid, user}
      user = find_by_email(claims[:email]) -> {:email, user}
      true -> nil
    end
  end

  defp find_by_email(nil), do: nil
  defp find_by_email(email), do: Repo.get_by(User, email: User.normalize_email(email))

  defp refresh_profile(user, claims, fields) do
    profile = claims |> Map.take(fields) |> Map.reject(fn {_field, value} -> is_nil(value) end)

    user
    |> User.changeset(profile)
    |> Repo.update()
  end

  @doc """
  Upserts a user from a Google `%Ueberauth.Auth{}` (the web redirect flow).
  Maps the auth struct onto provider claims and delegates to
  `upsert_user_from_provider/2`.

  Rejects with `{:error, :email_unverified}`, before touching the DB, unless
  Google's userinfo (`auth.extra.raw_info.user`) says the email is verified
  (`GoogleTokenValidator.email_verified?/1`, the same predicate native sign-in
  uses). Board invites bind by email, so an unverified address could otherwise
  claim someone else's invites and, because `users.email` is unique, lock the
  real owner out (RE343).
  """
  def upsert_user_from_google(%Ueberauth.Auth{} = auth) do
    if GoogleTokenValidator.email_verified?(google_userinfo(auth)) do
      upsert_user_from_provider(%{
        provider: "google",
        provider_uid: to_string(auth.uid),
        email: auth.info.email,
        name: auth.info.name,
        avatar_url: auth.info.image
      })
    else
      {:error, :email_unverified}
    end
  end

  # `ueberauth_google` stores Google's userinfo (string keys) at `extra.raw_info.user`.
  # Anything missing along that path reads as "no claims", which the predicate treats as unverified.
  defp google_userinfo(%Ueberauth.Auth{extra: %{raw_info: %{user: user}}}) when is_map(user), do: user
  defp google_userinfo(%Ueberauth.Auth{}), do: %{}

  @doc """
  Upserts and returns the fixed local dev user (dev/test only login
  bypass — see `GET /dev/login`). Never used in prod.
  """
  def ensure_dev_user! do
    case Repo.get_by(User, provider_uid: @dev_user_uid) do
      nil ->
        %User{provider: "dev", provider_uid: @dev_user_uid}
        |> User.changeset(%{email: @dev_user_email, name: "Dev User"})
        |> Repo.insert!()

      %User{} = user ->
        user
    end
  end

  @doc """
  Mints a user-scoped bearer token (RLY-80) for the native app's JSON calls. Returns
  `{:ok, %{user_api_token: token, token: raw}}` — the only place the raw
  `relayu_<prefix>_<secret>` ever exists; it is never persisted or re-retrievable. A
  user may hold several (one per signed-in device). The `relayu` sentinel keeps user
  tokens and board keys (`relay_…`, `Relay.ApiKeys`) mutually unauthenticable.
  """
  def create_user_api_token(%User{} = user, context \\ @default_user_token_context) do
    {prefix, secret, raw} = generate_user_token()

    changeset =
      UserApiToken.changeset(%UserApiToken{
        user_id: user.id,
        context: context,
        token_prefix: prefix,
        token_hash: hash_user_token_secret(secret),
        last_four: String.slice(secret, -4, 4)
      })

    with {:ok, token} <- Repo.insert(changeset) do
      prune_user_api_tokens(user, context)
      {:ok, %{user_api_token: token, token: raw}}
    end
  end

  @max_user_api_tokens 10

  @doc """
  How many `relayu_…` tokens a user keeps per context. Public so tests can assert the
  bound without hard-coding it.
  """
  def max_user_api_tokens, do: @max_user_api_tokens

  # The native app does not persist its bearer — it follows the session, so sign-in
  # AND every session verify mint one. That is a row per app launch, forever, and
  # nothing else prunes them. Reuse is impossible by construction (only the SHA-256
  # hash is kept; the raw is unrecoverable), so the only lever is dropping rows that
  # can no longer be in use — and a token from a previous launch is dead the moment
  # the app restarts, because the client kept no copy of it.
  #
  # Ordered by last_used_at (maintained on every authenticate), so a live sibling
  # device is evicted only if this user really has more than @max_user_api_tokens
  # of them in play at once. Scoped to one user + context: never touches anyone else.
  defp prune_user_api_tokens(%User{} = user, context) do
    keep =
      from(t in UserApiToken,
        where: t.user_id == ^user.id and t.context == ^context,
        order_by: [desc: coalesce(t.last_used_at, t.inserted_at), desc: t.id],
        limit: @max_user_api_tokens,
        select: t.id
      )

    Repo.delete_all(
      from(t in UserApiToken,
        where: t.user_id == ^user.id and t.context == ^context,
        where: t.id not in subquery(keep)
      )
    )
  end

  @doc """
  Authenticates a raw `relayu_<prefix>_<secret>` token: prefix lookup, constant-time
  hash compare, throttled `last_used_at` bump, returning `{:ok, user}`. Any malformed,
  unknown, or revoked token — including a board key — returns `:error`. This is what
  `RelayWeb.ApiUserAuth` calls.
  """
  def authenticate_user_api_token(raw_token) when is_binary(raw_token) do
    with ["relayu", prefix, secret] <- String.split(raw_token, "_", parts: 3),
         %UserApiToken{} = token <- Repo.get_by(UserApiToken, token_prefix: prefix),
         true <- Plug.Crypto.secure_compare(hash_user_token_secret(secret), token.token_hash) do
      touch_user_token_last_used(token)

      {:ok, Repo.preload(token, :user).user}
    else
      _not_authenticated -> :error
    end
  end

  def authenticate_user_api_token(_raw_token), do: :error

  @doc "Revokes (deletes) a user token. It stops authenticating immediately."
  def revoke_user_api_token(%UserApiToken{} = token), do: Repo.delete(token)

  # Throttled exactly like Relay.ApiKeys: a polling client must not write a row per
  # request, so only stamp when never used or older than the threshold.
  defp touch_user_token_last_used(%UserApiToken{last_used_at: last_used_at} = token) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    if user_token_stale?(last_used_at, now) do
      token
      |> Ecto.Changeset.change(last_used_at: now)
      |> Repo.update!()
    end
  end

  defp user_token_stale?(nil, _now), do: true

  defp user_token_stale?(last_used_at, now) do
    DateTime.diff(now, last_used_at, :second) >= @user_token_last_used_throttle_seconds
  end

  defp generate_user_token do
    prefix = random_user_token_hex(@user_token_prefix_bytes)
    secret = random_user_token_hex(@user_token_secret_bytes)
    {prefix, secret, "relayu_#{prefix}_#{secret}"}
  end

  defp random_user_token_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp hash_user_token_secret(secret), do: Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
end
