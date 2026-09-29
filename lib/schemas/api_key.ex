defmodule Schemas.ApiKey do
  @moduledoc """
  A board API key (MMF 08; multi-key since RE361). A board holds any number
  of named keys — typically one per machine — each authenticating as Relay AI
  on its board. The raw token is `relay_<token_prefix>_<secret>`:
  `token_prefix` is a public random id stored in the clear (lookup + masked
  display), the secret is stored only as a SHA-256 hash in `token_hash`
  (`last_four` supports the masked display). Only `name` is ever cast from
  input (`name_changeset/2`); every token field is set programmatically by
  `Relay.ApiKeys`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @name_max_length 80

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

  @doc "The longest a key's name may be."
  def name_max_length, do: @name_max_length

  @doc """
  Validates a programmatically-built key row (a struct, or a changeset from
  `name_changeset/2` carrying the cast name).
  """
  def changeset(api_key) do
    api_key
    |> change()
    |> validate_required([:board_id, :name, :token_prefix, :token_hash, :last_four])
    |> unique_constraint(:token_prefix)
    |> foreign_key_constraint(:board_id)
    |> foreign_key_constraint(:created_by_id)
  end

  @doc "The one input cast path: a key's display name (create and rename)."
  def name_changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name])
    |> update_change(:name, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @name_max_length)
  end

  # cast/3 already turns a whitespace-only name into nil (Ecto's default
  # empty_values), so the change can be nil here — leave it for validate_required.
  defp trim(nil), do: nil
  defp trim(name), do: String.trim(name)
end
