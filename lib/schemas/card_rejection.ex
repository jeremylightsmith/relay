defmodule Schemas.CardRejection do
  @moduledoc """
  The single open "changes requested" state on a card (RLY-30). Set/cleared
  only programmatically by `Relay.Cards` (never via `Card.changeset/2`), same
  discipline as `blocked_since`. Stage ids AND display names are snapshotted so
  the payload/CLI/drawer render self-contained and stable even if a stage is
  later renamed — matching how `:moved`/`:rejected` activity meta snapshots
  stage names.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :note, :string
    field :from_stage_id, :integer
    field :from_stage_name, :string
    field :to_stage_id, :integer
    field :to_stage_name, :string
    field :rejected_by, :string
    field :rejected_at, :utc_datetime
  end

  @doc "Validates a rejection snapshot; the note is the only required field."
  def changeset(rejection, attrs) do
    rejection
    |> cast(attrs, [
      :note,
      :from_stage_id,
      :from_stage_name,
      :to_stage_id,
      :to_stage_name,
      :rejected_by,
      :rejected_at
    ])
    |> validate_required([:note])
  end
end
