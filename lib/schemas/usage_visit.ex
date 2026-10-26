defmodule Schemas.UsageVisit do
  @moduledoc """
  One visit (RE475): a run of a signed-in user's activity with no gap longer than
  `Relay.Usage.idle_gap/0`, keyed by `(user_id, started_at)`. `seconds` is
  `Relay.Usage.visit_seconds/2` of the visit's first and last touch; `board_id` is the last board
  it touched and `card_refs` the last `Relay.Usage.max_card_refs/0` cards it opened.

  There is no changeset: `Relay.Usage.Tracker` is the only writer, through one `insert_all` upsert.
  """

  use Ecto.Schema

  schema "usage_visits" do
    field :started_at, :utc_datetime
    field :last_at, :utc_datetime
    field :seconds, :integer
    field :card_refs, {:array, :string}, default: []

    belongs_to :user, Schemas.User
    belongs_to :board, Schemas.Board

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
end
