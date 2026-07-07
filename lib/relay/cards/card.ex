defmodule Relay.Cards.Card do
  @moduledoc """
  A card on a board: a titled unit of work living in one stage. `position`
  orders cards within their stage; `ref_number` is the per-board sequence
  behind the human-facing ref (board key + number, e.g. RLY-12 — see
  `Relay.Cards.ref/2`). `board_id`, `stage_id`, `position`, and
  `ref_number` are set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "cards" do
    field :title, :string
    field :position, :integer
    field :tag, :string
    field :ref_number, :integer

    belongs_to :board, Relay.Boards.Board
    belongs_to :stage, Relay.Boards.Stage

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for user-supplied card attributes (`:title`, `:tag`).
  `board_id`, `stage_id`, `position`, and `ref_number` must already be
  set on the struct.
  """
  def changeset(card, attrs) do
    card
    |> cast(attrs, [:title, :tag])
    |> validate_required([:title])
    |> unique_constraint([:board_id, :ref_number], name: :cards_board_id_ref_number_index)
  end
end
