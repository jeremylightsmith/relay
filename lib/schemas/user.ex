defmodule Schemas.User do
  @moduledoc """
  A person who signed in. Identity is keyed on `provider_uid` first (the
  provider's stable `sub` claim — Google or Apple), then on the normalized
  verified `email` (see `Relay.Accounts.upsert_user_from_provider/2`).
  `provider` and `provider_uid` record the first provider the user signed in
  with; they are set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :provider, :string
    field :provider_uid, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for profile fields coming from the OAuth provider. `:email` is
  normalized (trimmed/downcased) so every email in the system is canonical —
  `Relay.Members` matches invite rows against `user.email` verbatim and
  relies on this.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :avatar_url])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> unique_constraint(:email)
    |> unique_constraint(:provider_uid)
  end

  @doc """
  The one email normalization (trim + downcase); `nil` stays `nil`. The
  changeset applies it, and account lookups by email go through it so a
  differently-cased claim still matches the stored row.
  """
  @spec normalize_email(String.t() | nil) :: String.t() | nil
  def normalize_email(nil), do: nil
  def normalize_email(email), do: email |> String.trim() |> String.downcase()
end
