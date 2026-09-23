# dagre_ex

A dependency-free Elixir port of the core of [dagre](https://github.com/dagrejs/dagre) — layered
(Sugiyama-style) layout for directed graphs.

**Geometry in, geometry out.** You give node sizes and edges (optionally with label sizes); you
get node positions, edge polylines and label centres. The library draws nothing — how to render a
polyline (orthogonal, rounded, spline) is up to you.

```elixir
Dagre.layout(
  nodes: [%{id: "a", width: 150, height: 56}, %{id: "b", width: 118, height: 56}],
  edges: [%{id: 0, from: "a", to: "b", label: %{width: 92, height: 16}}],
  ranksep: 68,
  nodesep: 24,
  edgesep: 12
)
#=> %Dagre.Layout{
#     nodes: %{"a" => %{x: 0, y: 0, width: 150, height: 56, rank: 0, order: 0}, ...},
#     edges: %{0 => %{points: [{75, 56}, ...], label: {75, 98}, reversed?: false}},
#     size: {150, 196}
#   }
```

- Node `x`/`y` are the **top-left** corner. All coordinates are non-negative integers; the
  bounding box starts at `{0, 0}` and `size` is its extent.
- `points` runs from the source anchor through every routed waypoint to the target anchor,
  always in the direction you declared the edge — even when cycle breaking reversed it
  internally (`reversed?: true` records that; it is informational only).
- Self-loops (`from == to`) are routed as a small stub loop off the node's right side.
- Only top-to-bottom (`rankdir: :tb`) is implemented; `:lr` is a planned option.

## Guarantees

These are properties of the algorithm, checked by the test suite over a set of fixture graphs
and random DAGs:

- no two node boxes overlap;
- no edge segment crosses a node box other than its own endpoints (long edges get a dummy node on
  every rank they cross, so they own a slot there);
- no label overlaps a node or another label (each label is a dummy node sized to the label, so it
  reserves real space on its rank);
- the same input always yields the same output.

## Pipeline

`Dagre.Acyclic` (greedy DFS feedback-arc-set) → `Dagre.Rank` (longest path + tightening) →
`Dagre.Normalize` (dummy chains, label dummies) → `Dagre.Order` (median + transpose crossing
reduction) → `Dagre.Position` (Brandes–Köpf) → `Dagre.Normalize.denormalize/2` +
`Dagre.Acyclic.undo/2`.

Not ported: network-simplex ranking (dagre's default ranker — longest path plus tightening is
used instead), compound/cluster graphs, and the `:lr`/`:bt`/`:rl` rank directions.

## Credit

This is an acknowledged port of [dagrejs/dagre](https://github.com/dagrejs/dagre) (MIT,
© Chris Pettitt and contributors). dagre's source is the best documentation for each phase.

## Licence

MIT — see [LICENSE](LICENSE).
