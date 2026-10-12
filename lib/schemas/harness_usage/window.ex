defmodule Schemas.HarnessUsage.Window do
  @moduledoc """
  One usage window of a harness's usage rule (RE436), e.g. Claude's 5-hour window: where a
  reading line carries the window's used share (`used_path`) and its reset time (`resets_path`),
  and the used percentage at which the runner pauses the harness (`pause_at`, 1–100).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Schemas.HarnessUsage

  @primary_key false
  embedded_schema do
    field :label, :string
    field :used_path, :string
    field :resets_path, :string
    field :pause_at, :integer
  end

  @type t :: %__MODULE__{}

  @doc "Validates a window: a trimmed label, two parseable paths and a 1–100 `pause_at`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(window, attrs) do
    window
    |> cast(attrs, [:label, :used_path, :resets_path, :pause_at])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:label, :used_path, :resets_path, :pause_at])
    |> HarnessUsage.validate_path(:used_path)
    |> HarnessUsage.validate_path(:resets_path)
    |> validate_number(:pause_at, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
  end
end
