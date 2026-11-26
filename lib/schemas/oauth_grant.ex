defmodule Schemas.OAuthGrant do
  @moduledoc """
  One user's connection to one OAuth client (RE519, owned by `Hamaca.Connections`),
  unique on `(user_id, oauth_client_id)`. `connected_at` is when the user last approved
  it, `last_used_at` the throttled stamp of its access tokens' use, and `revoked_at` set
  once the user disconnects it (re-authorizing clears it and reconnects the same row).
  Codes and tokens hang off the grant and cascade with it. Every field is programmatic.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "oauth_grants" do
    field :connected_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, Schemas.User
    belongs_to :oauth_client, Schemas.OAuthClient

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built grant row (nothing is cast from input)."
  def changeset(oauth_grant) do
    oauth_grant
    |> change()
    |> validate_required([:user_id, :oauth_client_id, :connected_at])
    |> unique_constraint([:user_id, :oauth_client_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:oauth_client_id)
  end
end
