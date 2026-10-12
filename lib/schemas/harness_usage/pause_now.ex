defmodule Schemas.HarnessUsage.PauseNow do
  @moduledoc """
  The "refused right now" signal of a harness's usage rule (RE436): a line matching `when` means
  the CLI has already refused work, so the runner pauses the harness at once — until the time at
  `resets_path` (optional; without it, the line's latest window reset).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Schemas.HarnessUsage

  @primary_key false
  embedded_schema do
    field :when, :string
    field :resets_path, :string
  end

  @type t :: %__MODULE__{}

  @doc "Validates the signal: `when` must be a condition, a present `resets_path` a path."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pause_now, attrs) do
    pause_now
    |> cast(attrs, [:when, :resets_path])
    |> validate_required([:when])
    |> HarnessUsage.validate_condition(:when)
    |> HarnessUsage.validate_path(:resets_path)
  end
end
