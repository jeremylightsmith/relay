defmodule Schemas.Card do
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
    field :description, :string
    field :position, :integer
    field :tag, :string
    field :ref_number, :integer

    field :status, Ecto.Enum,
      values: [:queued, :working, :needs_input, :in_review, :done],
      default: :queued

    field :progress, :integer

    belongs_to :board, Schemas.Board
    belongs_to :stage, Schemas.Stage
    has_many :owners, Schemas.CardOwner

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for user-supplied card attributes (`:title`, `:description`,
  `:tag`). `board_id`, `stage_id`, `position`, and `ref_number` must
  already be set on the struct and are never cast.
  """
  def changeset(card, attrs) do
    card
    |> cast(attrs, [:title, :description, :tag])
    |> validate_required([:title])
    |> unique_constraint([:board_id, :ref_number], name: :cards_board_id_ref_number_index)
  end

  @doc """
  Changeset for the card's baton state: `:status` (enum) and `:progress`
  (0–100, nullable — just stored and displayed; MMF 06 has no automation).
  Kept separate from `changeset/2` so title/description edits can never
  touch the baton and vice versa.
  """
  def status_changeset(card, attrs) do
    card
    |> cast(attrs, [:status, :progress])
    |> validate_required([:status])
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end
