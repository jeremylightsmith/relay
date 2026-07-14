defmodule Relay.Accounts do
  @moduledoc """
  The Accounts context: users and the current-user scope.

  Google OAuth is the only real sign-in path (open signup — any Google
  account gets a user). `ensure_dev_user!/0` backs the dev/test-only
  login bypass. Web/session concerns live in `RelayWeb.Auth`, not here.
  """

  use Boundary, deps: [Relay.Repo, Schemas], exports: [GoogleTokenValidator]

  alias Relay.Repo
  alias Schemas.User

  @dev_user_email "dev@relay.local"
  @dev_user_uid "dev-user"

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
end
