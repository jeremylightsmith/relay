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

    belongs_to :owner, Schemas.User
    has_many :stages, Schemas.Stage

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for board attributes. `owner_id` must already be set on the struct."
  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :slug, :key])
    |> validate_required([:name, :slug, :key])
    |> unique_constraint(:slug)
  end
end
