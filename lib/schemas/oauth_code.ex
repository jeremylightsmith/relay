defmodule Schemas.OAuthCode do
  @moduledoc """
  A single-use PKCE authorization code (RE519, owned by `Hamaca.Connections`). Only the
  SHA-256 hex of the raw code is stored (`code_hash`, unique — the lookup key), with the
  S256 `code_challenge`, the exact `redirect_uri` and optional `resource` it was issued
  for, its short `expires_at`, and `used_at` once exchanged. Every field is programmatic.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "oauth_codes" do
    field :code_hash, :string
    field :code_challenge, :string
    field :redirect_uri, :string
    field :resource, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :grant, Schemas.OAuthGrant

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built code row (nothing is cast from input)."
  def changeset(oauth_code) do
    oauth_code
    |> change()
    |> validate_required([:grant_id, :code_hash, :code_challenge, :redirect_uri, :expires_at])
    |> unique_constraint(:code_hash)
    |> foreign_key_constraint(:grant_id)
  end
end
