defmodule Schemas.OAuthToken do
  @moduledoc """
  A hashed OAuth access or refresh token (RE519, owned by `Hamaca.Connections`). The raw
  token is `relaym_<token_prefix>_<secret>`: `token_prefix` is a public random id stored
  in the clear (lookup), the secret only as a SHA-256 hash in `token_hash`. `kind` is
  `:access` or `:refresh` (`kinds/0`); `expires_at` bounds each. Every field is
  programmatic, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds [:access, :refresh]

  schema "oauth_tokens" do
    field :kind, Ecto.Enum, values: @kinds
    field :token_prefix, :string
    field :token_hash, :string
    field :expires_at, :utc_datetime

    belongs_to :grant, Schemas.OAuthGrant

    timestamps(type: :utc_datetime)
  end

  @doc "The token kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Validates a programmatically-built token row (nothing is cast from input)."
  def changeset(oauth_token) do
    oauth_token
    |> change()
    |> validate_required([:grant_id, :kind, :token_prefix, :token_hash, :expires_at])
    |> unique_constraint(:token_prefix)
    |> foreign_key_constraint(:grant_id)
  end
end
