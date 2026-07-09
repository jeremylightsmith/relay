defmodule Schemas.Board do
  @moduledoc """
  A user's kanban board. One board per user for now (MMF 19 adds more).
  `slug` is stored for future slug-routing (MMF 19); `key` is the short
  card-ref prefix (e.g. "RLY-12", used from MMF 03). `owner_id` is set
  programmatically, never cast from input. `card_seq` is the per-board
  card-ref counter (MMF 03), bumped under a row lock by
  `Relay.Cards.create_card/2` and never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "boards" do
    field :name, :string, default: "My board"
    field :slug, :string
    field :key, :string, default: "RLY"
    field :card_seq, :integer, default: 0
    field :archived_at, :utc_datetime

    belongs_to :owner, Schemas.User
    has_many :stages, Schemas.Stage

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for board attributes. `owner_id` must already be set on the struct."
  def changeset(board, attrs) do
    board
    # `empty_values: []` disables Ecto's default cast behavior of silently
    # substituting a blank/whitespace param with the field's schema default
    # (`name`'s default is "My board") — without this, submitting a blank
    # name would reset it to "My board" instead of failing validation below.
    |> cast(attrs, [:name, :slug, :key], empty_values: [])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :slug, :key])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase letters, numbers, and hyphens"
    )
    |> unique_constraint(:slug)
  end

  @doc "True when the board has been archived (read-only)."
  def archived?(%__MODULE__{archived_at: nil}), do: false
  def archived?(%__MODULE__{}), do: true
end
