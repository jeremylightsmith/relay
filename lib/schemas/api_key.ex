defmodule Schemas.ApiKey do
  @moduledoc """
  A board's API key (MMF 08). One active key per board for now (unique
  index on `board_id`); the table keeps `board_id` so going multi-key
  later is a constraint change, not a reshape. The raw token is
  `relay_<token_prefix>_<secret>`: `token_prefix` is a public random id
  stored in the clear (lookup + masked display), the secret is stored
  only as a SHA-256 hash in `token_hash` (`last_four` supports the
  masked display). All fields are set programmatically by
  `Relay.ApiKeys`, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "api_keys" do
    field :name, :string
    field :token_prefix, :string
    field :token_hash, :string
    field :last_four, :string
    field :last_used_at, :utc_datetime

    belongs_to :board, Schemas.Board
    belongs_to :created_by, Schemas.User, foreign_key: :created_by_id

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built key row (nothing is cast from input)."
  def changeset(api_key) do
    api_key
    |> change()
    |> validate_required([:board_id, :name, :token_prefix, :token_hash, :last_four])
    |> unique_constraint(:board_id)
    |> unique_constraint(:token_prefix)
    |> foreign_key_constraint(:board_id)
    |> foreign_key_constraint(:created_by_id)
  end
end
