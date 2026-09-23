defmodule Dagre.Layout do
  @moduledoc """
  The result of `Dagre.layout/1`.

    * `nodes` — per node id: `x`/`y` (top-left corner), `width`/`height` (as
      given), `rank` (the node's layer, top to bottom; layers that hold only
      label or long-edge dummies count too, so real nodes' ranks may skip
      values) and `order` (its index, left to right, within that layer).
    * `edges` — per edge id: `points`, a polyline from the source anchor through
      every routed waypoint to the target anchor, always in the caller's
      direction; `label`, the centre of the edge's label or `nil`; and
      `reversed?`, whether cycle breaking reversed the edge (informational only).
    * `size` — `{width, height}` of the bounding box, which starts at `{0, 0}`.
  """

  @enforce_keys [:nodes, :edges, :size]
  defstruct [:nodes, :edges, :size]

  @type point :: {non_neg_integer(), non_neg_integer()}
  @type node_layout :: %{
          x: non_neg_integer(),
          y: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          rank: non_neg_integer(),
          order: non_neg_integer()
        }
  @type edge_layout :: %{points: [point()], label: point() | nil, reversed?: boolean()}
  @type t :: %__MODULE__{
          nodes: %{term() => node_layout()},
          edges: %{term() => edge_layout()},
          size: {non_neg_integer(), non_neg_integer()}
        }
end
