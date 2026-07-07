defmodule Relay.Boards.Stage do
  @moduledoc """
  A column on a board. `category` groups stages under the board's category
  band (unstarted → in_progress → complete); `owner` says whose turn work
  in this stage is — human (blue) or ai (violet). `board_id` is set
  programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "stages" do
    field :name, :string
    field :position, :integer
    field :category, Ecto.Enum, values: [:unstarted, :in_progress, :complete]
    field :owner, Ecto.Enum, values: [:human, :ai]

    belongs_to :board, Relay.Boards.Board

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for stage attributes. `board_id` must already be set on the struct."
  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:name, :position, :category, :owner])
    |> validate_required([:name, :position, :category, :owner])
    |> unique_constraint(:position, name: :stages_board_id_position_index)
  end
end
