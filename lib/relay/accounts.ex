defmodule Relay.Accounts do
  @moduledoc """
  The Accounts context: users, the current-user scope, and user-scoped API tokens.

  Google OAuth is the only real sign-in path (open signup — any Google
  account gets a user). `ensure_dev_user!/0` backs the dev/test-only
  login bypass. Web/session concerns live in `RelayWeb.Auth`, not here.
  `create_user_api_token/2` and `authenticate_user_api_token/1` mint and verify
  the bearer tokens the native app uses for its JSON calls.
  """

  use Boundary, deps: [Relay.Repo, Schemas], exports: [GoogleTokenValidator]

  alias Relay.Repo
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
  Upserts a user from normalized provider claims (the provider-agnostic seam).
  Looks up by `provider_uid`, inserting a `%User{provider:, provider_uid:}` on
  first sign-in and refreshing `email`/`name`/`avatar_url` on return visits.
  Every sign-in path (Google web + native, future Apple/GitHub) flows through here.
  """
  def upsert_user_from_provider(%{provider: provider, provider_uid: provider_uid} = claims) do
    profile = Map.take(claims, [:email, :name, :avatar_url])

    case Repo.get_by(User, provider_uid: provider_uid) do
      nil ->
        %User{provider: provider, provider_uid: provider_uid}
        |> User.changeset(profile)
        |> Repo.insert()

      %User{} = user ->
        user
        |> User.changeset(profile)
        |> Repo.update()
    end
  end

  @doc """
  Upserts a user from a Google `%Ueberauth.Auth{}` (the web redirect flow).
  Maps the auth struct onto provider claims and delegates to
  `upsert_user_from_provider/1`.
  """
  def upsert_user_from_google(%Ueberauth.Auth{} = auth) do
    upsert_user_from_provider(%{
      provider: "google",
      provider_uid: to_string(auth.uid),
      email: auth.info.email,
      name: auth.info.name,
      avatar_url: auth.info.image
    })
  end

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
      {:ok, %{user_api_token: token, token: raw}}
    end
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
