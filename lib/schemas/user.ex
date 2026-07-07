defmodule Schemas.User do
  @moduledoc """
  A person who signed in. Identity is keyed on `provider_uid`
  (Google's stable `sub` claim); `provider` and `provider_uid` are set
  programmatically, never cast from input.
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

  @doc "Changeset for profile fields coming from the OAuth provider."
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :avatar_url])
    |> validate_required([:email])
    |> unique_constraint(:email)
    |> unique_constraint(:provider_uid)
  end
end
