defmodule Schemas.Stage do
  @moduledoc """
  A column on a board. `category` groups stages under the board's category
  band (unstarted → planning → in_progress → complete); `owner` says who work in this
  stage is **meant for** — human (blue) or ai (violet). It is NOT the
  card's owner (cards carry their own owner list from MMF 06). `board_id`
  is set programmatically, never cast from input. `wip_limit` is the
  optional MMF 11 WIP limit — `nil` means no limit; it is only meaningful
  on `lane: :main` stages. `approval_gate`/`reject_to_stage_id` are the
  MMF 13 checkpoint config — the reject target must be a main-lane stage
  on the same board (validated in `Relay.Boards.update_stage/2`; nil =
  the gate's own main lane).
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
    field :wip_limit, :integer
    field :approval_gate, :boolean, default: false

    belongs_to :board, Schemas.Board
    belongs_to :parent, Schemas.Stage
    belongs_to :reject_to_stage, Schemas.Stage
    has_many :sublanes, Schemas.Stage, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for stage attributes. `board_id` must already be set on the struct."
  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:name, :description, :position, :category, :owner, :wip_limit, :approval_gate, :reject_to_stage_id])
    |> validate_required([:name, :position, :category, :owner])
    |> validate_number(:wip_limit, greater_than: 0)
    |> unique_constraint(:position, name: :stages_board_id_position_index)
  end
end
