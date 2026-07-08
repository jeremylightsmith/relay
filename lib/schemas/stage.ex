defmodule Schemas.Stage do
  @moduledoc """
  A column on a board. `category` groups stages under the board's category
  band (unstarted → planning → in_progress → complete); `owner` says who work in this
  stage is **meant for** — human (blue) or ai (violet). It is NOT the
  card's owner (cards carry their own owner list from MMF 06). `board_id`
  is set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "stages" do
    field :name, :string
    field :description, :string
    field :position, :integer
    field :category, Ecto.Enum, values: [:unstarted, :planning, :in_progress, :complete]
    field :owner, Ecto.Enum, values: [:human, :ai]
    field :lane, Ecto.Enum, values: [:main, :review, :done], default: :main

    belongs_to :board, Schemas.Board
    belongs_to :parent, Schemas.Stage
    has_many :sublanes, Schemas.Stage, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for stage attributes. `board_id` must already be set on the struct."
  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:name, :description, :position, :category, :owner])
    |> validate_required([:name, :position, :category, :owner])
    |> unique_constraint(:position, name: :stages_board_id_position_index)
  end
end
