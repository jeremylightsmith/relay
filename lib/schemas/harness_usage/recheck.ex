defmodule Schemas.HarnessUsage.Recheck do
  @moduledoc """
  How a paused, idle harness is re-checked (RE436): a cheap run on `model` (one of the harness's
  own models) every `interval_min` minutes, whose output carries a fresh reading.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :model, :string
    field :interval_min, :integer
  end

  @type t :: %__MODULE__{}

  @doc "Validates a recheck against the harness's current `models`."
  @spec changeset(t(), map(), [String.t()]) :: Ecto.Changeset.t()
  def changeset(recheck, attrs, models) do
    recheck
    |> cast(attrs, [:model, :interval_min])
    |> validate_required([:model, :interval_min])
    |> validate_inclusion(:model, models, message: "is not one of this harness's models")
    |> validate_number(:interval_min, greater_than: 0)
  end
end
