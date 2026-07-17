defmodule Schemas.Flow.Edge do
  @moduledoc """
  One edge of a flow's embedded graph (ADR 0006). `from`/`to` name node keys
  or the `"start"`/`"done"` sentinels; `on` is the closed outcome set (nil
  only on the start edge — enforced on Schemas.Flow). An `on: :needs_input`
  edge is valid data even though the engine parks without one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :from, :string
    field :to, :string
    field :on, Ecto.Enum, values: [:succeeded, :failed, :partial, :needs_input]
    field :max_loops, :integer
  end

  @doc "Validates one edge; graph-level rules (endpoints, routing) live on Schemas.Flow."
  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:from, :to, :on, :max_loops])
    |> validate_required([:from, :to])
    |> validate_number(:max_loops, greater_than: 0)
  end
end
