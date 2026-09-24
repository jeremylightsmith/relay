defmodule Dagre do
  @moduledoc """
  Layered (Sugiyama-style) layout for directed graphs — an Elixir port of the core
  of [dagrejs/dagre](https://github.com/dagrejs/dagre) (MIT, © Chris Pettitt and
  contributors). dagre's source is the best reference for every phase here.

  Geometry in, geometry out: you give node sizes and edges (optionally with label
  sizes); you get node positions, edge polylines and label centres. Nothing is
  drawn — how to render a polyline (orthogonal, rounded, spline) is the caller's
  call.

      Dagre.layout(
        nodes: [%{id: "a", width: 150, height: 56}, %{id: "b", width: 118, height: 56}],
        edges: [%{id: 0, from: "a", to: "b", label: %{width: 92, height: 16}}],
        ranksep: 68,
        nodesep: 24,
        edgesep: 12
      )
      #=> %Dagre.Layout{nodes: %{"a" => %{x: ..., y: ..., ...}, ...}, edges: %{0 => ...}, size: {w, h}}

  ## Pipeline

  Each phase is its own module:

    1. `Dagre.Acyclic` — reverse back-edges so the graph is a DAG.
    2. `Dagre.Rank` — assign every node a layer.
    3. `Dagre.Normalize` — split long edges into dummy chains; give each label a
       dummy sized to it.
    4. `Dagre.Order` — order each layer to reduce crossings.
    5. `Dagre.Position` — assign coordinates (Brandes–Köpf for x).
    6. `Dagre.Normalize.denormalize/2` and `Dagre.Acyclic.undo/2` — turn chains
       back into polylines in the caller's direction.

  Self-loops are set aside first and routed at the end by `Dagre.SelfLoop`.

  ## Options

    * `:nodes` — `[%{id: term, width: non_neg_integer, height: non_neg_integer}]`
    * `:edges` — `[%{id: term, from: node_id, to: node_id, label: %{width:, height:} | nil, weight: pos_integer}]`
      (`label` and `weight` may be omitted). `weight` (default 1) says how much
      an edge wants to be straight: when the edges heavier than all their
      neighbours form a single directed path, every node on it gets the same
      x-centre, so the path is drawn as one vertical line. Only `Dagre.Position`
      reads it — ranking and crossing reduction ignore weight.
    * `:rankdir` — `:tb` (default; top to bottom). `:lr` is a planned future
      option and raises today.
    * `:ranksep` — vertical gap between layers (default 50). When any edge has
      a label, labels get layers of their own and each gap is halved, as in dagre.
    * `:nodesep` — minimum horizontal gap between real nodes (default 50).
    * `:edgesep` — minimum horizontal gap beside an edge's slot (default 20).

  Raises `ArgumentError` on invalid input.
  """

  alias Dagre.Acyclic
  alias Dagre.Graph
  alias Dagre.Layout
  alias Dagre.Normalize
  alias Dagre.Order
  alias Dagre.Position
  alias Dagre.Rank
  alias Dagre.SelfLoop

  @defaults [rankdir: :tb, ranksep: 50, nodesep: 50, edgesep: 20]

  @doc "Lays out a graph. See the moduledoc for the options and `Dagre.Layout` for the result."
  @spec layout(keyword()) :: Layout.t()
  def layout(opts) when is_list(opts) do
    config = config!(Keyword.merge(@defaults, opts))
    {nodes, index} = nodes!(Keyword.get(opts, :nodes, []))
    {loops, edges} = opts |> Keyword.get(:edges, []) |> edges!(index) |> Enum.split_with(&(&1.from == &1.to))

    loop_plan = SelfLoop.plan(loops, config.edgesep)
    labelled? = Enum.any?(edges, & &1.label)
    ranksep = if labelled?, do: div(config.ranksep, 2), else: config.ranksep

    {graph, reversed} = nodes |> build(edges, loop_plan, if(labelled?, do: 2, else: 1)) |> Acyclic.run()
    {graph, chains} = graph |> Rank.run() |> Normalize.run()

    graph =
      graph
      |> Order.run()
      |> Position.run(ranksep: ranksep, nodesep: config.nodesep, edgesep: config.edgesep)

    routed = graph |> Normalize.denormalize(chains) |> Acyclic.undo(reversed)

    %Layout{
      nodes: node_layouts(graph, nodes),
      edges: Map.merge(edge_layouts(routed, edges), loop_layouts(graph, loop_plan, config.edgesep)),
      size: size(graph)
    }
  end

  defp config!(opts) do
    unless opts[:rankdir] == :tb do
      raise ArgumentError, "rankdir #{inspect(opts[:rankdir])} is not supported; only :tb is implemented"
    end

    for key <- [:ranksep, :nodesep, :edgesep], not non_neg_integer?(opts[key]) do
      raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(opts[key])}"
    end

    Map.new(Keyword.take(opts, [:ranksep, :nodesep, :edgesep]))
  end

  # Internally nodes are 0..n-1 and edges 0..m-1 in input order; caller ids are
  # only mapped back on the way out.
  defp nodes!(nodes) do
    nodes = Enum.map(nodes, &node!/1)
    index = nodes |> Enum.with_index() |> Map.new(fn {node, i} -> {node.id, i} end)

    if map_size(index) != length(nodes) do
      raise ArgumentError, "node ids must be unique"
    end

    {nodes, index}
  end

  defp node!(%{id: _, width: w, height: h} = node) do
    unless non_neg_integer?(w) and non_neg_integer?(h) do
      raise ArgumentError, "node width/height must be non-negative integers: #{inspect(node)}"
    end

    Map.take(node, [:id, :width, :height])
  end

  defp node!(node), do: raise(ArgumentError, "a node needs :id, :width and :height: #{inspect(node)}")

  defp edges!(edges, index) do
    edges = edges |> Enum.with_index() |> Enum.map(fn {edge, i} -> edge!(edge, i, index) end)

    if edges |> Enum.uniq_by(& &1.id) |> length() != length(edges) do
      raise ArgumentError, "edge ids must be unique"
    end

    edges
  end

  defp edge!(%{id: id, from: from, to: to} = edge, i, index) do
    for endpoint <- [from, to], not Map.has_key?(index, endpoint) do
      raise ArgumentError, "edge #{inspect(id)} refers to unknown node #{inspect(endpoint)}"
    end

    %{
      index: i,
      id: id,
      from: index[from],
      to: index[to],
      label: label!(Map.get(edge, :label), id),
      weight: weight!(Map.get(edge, :weight, 1), id)
    }
  end

  defp edge!(edge, _i, _index), do: raise(ArgumentError, "an edge needs :id, :from and :to: #{inspect(edge)}")

  defp label!(nil, _id), do: nil

  defp label!(%{width: w, height: h}, id) do
    unless non_neg_integer?(w) and non_neg_integer?(h) do
      raise ArgumentError, "label width/height of edge #{inspect(id)} must be non-negative integers"
    end

    {w, h}
  end

  defp label!(label, id),
    do: raise(ArgumentError, "label of edge #{inspect(id)} needs :width and :height: #{inspect(label)}")

  defp weight!(weight, _id) when is_integer(weight) and weight > 0, do: weight

  defp weight!(weight, id),
    do: raise(ArgumentError, "weight of edge #{inspect(id)} must be a positive integer, got: #{inspect(weight)}")

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0

  defp build(nodes, edges, loop_plan, minlen) do
    graph =
      nodes
      |> Enum.with_index()
      |> Enum.reduce(Graph.new(), fn {node, i}, graph ->
        %{width: extra_w, height: min_h} = Map.get(loop_plan, i, %{width: 0, height: 0})

        attrs = %{
          width: node.width + extra_w,
          height: max(node.height, min_h),
          box: {node.width, node.height},
          dummy: nil
        }

        Graph.add_node(graph, i, attrs)
      end)

    Enum.reduce(edges, graph, fn edge, graph ->
      Graph.add_edge(graph, edge.index, edge.from, edge.to, %{minlen: minlen, label: edge.label, weight: edge.weight})
    end)
  end

  defp node_layouts(graph, nodes) do
    nodes
    |> Enum.with_index()
    |> Map.new(fn {node, i} ->
      attrs = Graph.node(graph, i)
      {x, y, w, h} = Position.box(attrs)
      {node.id, %{x: x, y: y, width: w, height: h, rank: attrs.rank, order: attrs.order}}
    end)
  end

  defp edge_layouts(routed, edges) do
    Map.new(edges, fn edge -> {edge.id, Map.fetch!(routed, edge.index)} end)
  end

  defp loop_layouts(graph, loop_plan, edgesep) do
    for {node, %{slots: slots}} <- loop_plan, slot <- slots, into: %{} do
      attrs = Graph.node(graph, node)
      layout_box = {attrs.x, attrs.y, attrs.width, attrs.height}
      {slot.id, Map.put(SelfLoop.route(Position.box(attrs), layout_box, slot, edgesep), :reversed?, false)}
    end
  end

  defp size(graph) do
    graph
    |> Graph.nodes()
    |> Enum.map(&Graph.node(graph, &1))
    |> Enum.reduce({0, 0}, fn attrs, {w, h} ->
      {_top, bottom} = attrs.band
      {max(w, attrs.x + attrs.width), max(h, bottom)}
    end)
  end
end
