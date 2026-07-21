defmodule Schemas.Flow.Edge do
  @moduledoc """
  One edge of a flow's embedded graph (ADR 0006). `from`/`to` name node keys
  or the `"start"`/`"done"`/`"needs_input"` sentinels; `on` is the closed
  outcome set (nil only on the start edge — enforced on Schemas.Flow). An
  `on: :needs_input` edge is valid data even though the engine parks without
  one. `"needs_input"` as a `to` (RLY-194) is a third, `to`-only sentinel
  (never a `from`, never a node key) that parks the run — the counterpart
  edge-level park to the `on: :needs_input` outcome-level one above.

  `when` guards the edge on the enclosing `foreach`'s remaining count, which
  is what lets TWO edges leave one node on the SAME outcome (nil = unguarded).
  The router prefers a satisfied guard and falls back to the unguarded edge.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :from, :string
    field :to, :string
    field :on, Ecto.Enum, values: [:succeeded, :failed, :partial, :needs_input]
    field :max_loops, :integer
    field :when, Ecto.Enum, values: [:foreach_remaining, :foreach_exhausted]
  end

  @doc "Validates one edge; graph-level rules (endpoints, routing) live on Schemas.Flow."
  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:from, :to, :on, :max_loops, :when])
    |> validate_required([:from, :to])
    |> validate_number(:max_loops, greater_than: 0)
  end
end
