defmodule RelayWeb.FlowLayoutTest do
  use ExUnit.Case, async: true

  alias RelayWeb.FlowLayout

  # RE333: the reported defects (labels piled on top of each other, edges drawn through node
  # boxes) showed up in the shipped Code flow, so the shipped flows ARE the corpus — every
  # invariant below runs over all of them, not over a hand-picked fixture.
  defp library, do: Relay.Flows.DefaultLibrary.all()

  defp code_flow do
    flow = Enum.find(library(), &(&1.key == "code"))
    {flow.nodes, flow.edges}
  end

  # A branch that never rejoins and more than one terminal — the shape the old two-column layout
  # could not express. `ship` and `publish` both reach done; `escalate` is a dead end; `fix`
  # self-loops on failure.
  defp branchy_flow do
    nodes = [
      %{key: "triage", type: :gate},
      %{key: "fix", type: :agent},
      %{key: "ship", type: :shell},
      %{key: "write_docs", type: :agent},
      %{key: "publish", type: :shell},
      %{key: "escalate", type: :human}
    ]

    edges = [
      %{from: "start", to: "triage", on: nil},
      %{from: "triage", to: "fix", on: :succeeded},
      %{from: "triage", to: "write_docs", on: :failed},
      %{from: "fix", to: "ship", on: :succeeded},
      %{from: "fix", to: "fix", on: :failed, max_loops: 2},
      %{from: "ship", to: "done", on: :succeeded},
      %{from: "write_docs", to: "publish", on: :succeeded},
      %{from: "publish", to: "done", on: :succeeded},
      %{from: "write_docs", to: "escalate", on: :failed}
    ]

    {nodes, edges}
  end

  defp node_type(node), do: Map.get(node, :type, :agent)

  # Node boxes exactly as the renderer draws them: top-left from the layout, size from node_size/1.
  defp boxes(nodes, layout) do
    Map.new(nodes, fn node ->
      {x, y} = Map.fetch!(layout.positions, node.key)
      {w, h} = FlowLayout.node_size(node_type(node))
      {node.key, {x, y, w, h}}
    end)
  end

  # Label pills exactly as the renderer draws them: centred on the route's label point
  # (`transform:translate(-50%,-50%)`) and sized by the same measurement the layout reserved.
  defp label_rects(edges, layout) do
    edges
    |> Enum.with_index()
    |> Enum.flat_map(fn {edge, i} ->
      case layout.routes[i] do
        %{label: {cx, cy}} ->
          {w, h} = FlowLayout.label_size(edge)
          [{i, {cx - div(w, 2), cy - div(h, 2), w, h}}]

        _ ->
          []
      end
    end)
  end

  defp segments(points), do: Enum.chunk_every(points, 2, 1, :discard)

  # Strict interior overlap — rects that merely share a border do not overlap.
  defp overlap?({ax, ay, aw, ah}, {bx, by, bw, bh}), do: ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah

  # An axis-aligned segment passes THROUGH a box when it runs strictly inside it. Touching the
  # border — where an edge meets its own endpoint, or skims past a neighbour — is not a crossing.
  defp crosses?([{x, y1}, {x, y2}], {bx, by, bw, bh}),
    do: x > bx and x < bx + bw and max(y1, y2) > by and min(y1, y2) < by + bh

  defp crosses?([{x1, y}, {x2, y}], {bx, by, bw, bh}),
    do: y > by and y < by + bh and max(x1, x2) > bx and min(x1, x2) < bx + bw

  describe "invariants over every shipped flow (RE333)" do
    test "no two node boxes overlap" do
      for flow <- library() do
        boxes = boxes(flow.nodes, FlowLayout.layout(flow.nodes, flow.edges))

        for {a, box_a} <- boxes, {b, box_b} <- boxes, a < b do
          refute overlap?(box_a, box_b), "#{flow.key}: #{a} overlaps #{b}"
        end
      end
    end

    test "every route is an axis-aligned polyline, so the renderer's rounded-corner builder applies" do
      for flow <- library(), {i, %{points: points}} <- FlowLayout.layout(flow.nodes, flow.edges).routes do
        assert length(points) >= 2, "#{flow.key}: edge #{i} has fewer than two points"

        for [{x1, y1}, {x2, y2}] <- segments(points) do
          assert x1 == x2 or y1 == y2,
                 "#{flow.key}: edge #{i} has a diagonal segment #{inspect({{x1, y1}, {x2, y2}})}"
        end
      end
    end

    test "no edge segment passes through a node box other than its own endpoints" do
      for flow <- library() do
        layout = FlowLayout.layout(flow.nodes, flow.edges)
        boxes = boxes(flow.nodes, layout)

        for {edge, i} <- Enum.with_index(flow.edges),
            Map.has_key?(layout.routes, i),
            segment <- segments(layout.routes[i].points),
            {key, box} <- boxes,
            key not in [edge.from, edge.to] do
          refute crosses?(segment, box),
                 "#{flow.key}: edge #{i} (#{edge.from} → #{edge.to}) passes through #{key}"
        end
      end
    end

    test "no label rect overlaps a node box or another label rect" do
      for flow <- library() do
        layout = FlowLayout.layout(flow.nodes, flow.edges)
        boxes = boxes(flow.nodes, layout)
        labels = label_rects(flow.edges, layout)

        for {i, label} <- labels, {key, box} <- boxes do
          refute overlap?(label, box), "#{flow.key}: the label of edge #{i} sits on node #{key}"
        end

        for {i, a} <- labels, {j, b} <- labels, i < j do
          refute overlap?(a, b), "#{flow.key}: the labels of edges #{i} and #{j} overlap"
        end
      end
    end

    # Guards the label invariant against passing vacuously: every drawn, non-start Code flow edge
    # must actually have a placed label for the overlap check above to examine.
    test "every drawn non-start Code flow edge has a placed label" do
      {nodes, edges} = code_flow()
      layout = FlowLayout.layout(nodes, edges)

      drawn =
        for {edge, i} <- Enum.with_index(edges), Map.has_key?(layout.routes, i), edge.from != "start", do: i

      assert length(drawn) > 20
      assert edges |> label_rects(layout) |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.sort(drawn)
    end

    test "laying out the same flow twice yields equal results" do
      for flow <- library() do
        assert FlowLayout.layout(flow.nodes, flow.edges) == FlowLayout.layout(flow.nodes, flow.edges),
               "#{flow.key}: layout is not deterministic"
      end
    end
  end

  describe "layout/2 contract" do
    test "returns positions, size, routes, start_point, done_point and parks" do
      {nodes, edges} = code_flow()

      assert nodes |> FlowLayout.layout(edges) |> Map.keys() |> Enum.sort() ==
               [:done_point, :parks, :positions, :routes, :size, :start_point]
    end

    test "positions hold exactly the flow's own nodes — start and done stay internal" do
      for flow <- library() do
        positions = FlowLayout.layout(flow.nodes, flow.edges).positions
        assert positions |> Map.keys() |> Enum.sort() == flow.nodes |> Enum.map(& &1.key) |> Enum.sort()
      end
    end

    test "start_point and done_point lie inside the canvas" do
      {branchy_nodes, branchy_edges} = branchy_flow()

      cases =
        Enum.map(library(), &{&1.nodes, &1.edges}) ++
          [{branchy_nodes, branchy_edges}, {[], [%{from: "start", to: "done", on: nil}]}]

      for {nodes, edges} <- cases do
        %{size: {w, h}, start_point: {sx, sy}, done_point: {dx, dy}} = FlowLayout.layout(nodes, edges)
        assert sx in 0..w and sy in 0..h
        assert dx in 0..w and dy in 0..h
      end
    end

    test "every shipped flow's entry edge leaves start_point and its exit edge lands on done_point" do
      for flow <- library() do
        layout = FlowLayout.layout(flow.nodes, flow.edges)

        for {edge, i} <- Enum.with_index(flow.edges), Map.has_key?(layout.routes, i) do
          points = layout.routes[i].points
          if edge.from == "start", do: assert(hd(points) == layout.start_point)
          if edge.to == "done", do: assert(List.last(points) == layout.done_point)
        end
      end
    end

    test "start edges carry no label point; every other drawn edge does" do
      {nodes, edges} = code_flow()
      %{routes: routes} = FlowLayout.layout(nodes, edges)

      for {edge, i} <- Enum.with_index(edges), Map.has_key?(routes, i) do
        if edge.from == "start",
          do: assert(routes[i].label == nil),
          else: assert(match?({_, _}, routes[i].label))
      end
    end

    test "a diverging branch that never rejoins lays out with every node in its own box" do
      {nodes, edges} = branchy_flow()
      layout = FlowLayout.layout(nodes, edges)
      boxes = boxes(nodes, layout)

      assert map_size(layout.positions) == length(nodes)
      assert map_size(layout.routes) == length(edges)

      for {a, box_a} <- boxes, {b, box_b} <- boxes, a < b, do: refute(overlap?(box_a, box_b))

      # each terminal branch is its own path: ship → done and publish → done do not share a route
      ship = Enum.find_index(edges, &(&1.from == "ship"))
      publish = Enum.find_index(edges, &(&1.from == "publish"))
      refute layout.routes[ship].points == layout.routes[publish].points
    end

    test "a foreach head's self-loop is routed and labelled clear of its node" do
      nodes = [%{key: "head", type: :agent, foreach: "card.sub_tasks"}, %{key: "tail", type: :gate}]

      edges = [
        %{from: "start", to: "head", on: nil},
        %{from: "head", to: "head", on: :succeeded, when: :foreach_remaining},
        %{from: "head", to: "tail", on: :succeeded, when: :foreach_exhausted},
        %{from: "tail", to: "done", on: :succeeded}
      ]

      layout = FlowLayout.layout(nodes, edges)
      assert length(layout.routes[1].points) >= 4
      assert [{1, label}] = edges |> label_rects(layout) |> Enum.filter(&(elem(&1, 0) == 1))
      refute overlap?(label, boxes(nodes, layout)["head"])
    end

    test "a zero-node flow routes a bare start → done edge as one straight drop" do
      %{positions: positions, routes: routes, start_point: start_point, done_point: done_point} =
        FlowLayout.layout([], [%{from: "start", to: "done", on: nil}])

      assert positions == %{}
      assert routes[0].points == [start_point, done_point]
    end

    test "an unconnected node still gets a position" do
      nodes = [%{key: "a", type: :agent}, %{key: "orphan", type: :shell}]
      edges = [%{from: "start", to: "a", on: nil}, %{from: "a", to: "done", on: :succeeded}]

      assert %{"orphan" => {_, _}} = FlowLayout.layout(nodes, edges).positions
    end
  end

  describe "edge labels" do
    test "the pill text joins the outcome, the foreach guard wording and max loops" do
      assert FlowLayout.edge_label(%{on: :failed, max_loops: 3}) == "failed · max 3"
      assert FlowLayout.edge_label(%{on: :succeeded, when: :foreach_remaining}) == "succeeded · while tasks remain"
      assert FlowLayout.edge_label(%{on: :succeeded, when: :foreach_exhausted}) == "succeeded · all tasks done"
      assert FlowLayout.edge_label(%{on: nil}) == ""
    end

    test "label_size approximates the 9.5px monospace pill as chars × 5.7 + 12 wide, 16 tall" do
      assert FlowLayout.label_size(%{on: :failed, max_loops: 3}) == {92, 16}
      assert FlowLayout.label_size(%{on: :succeeded}) == {64, 16}
    end
  end

  describe "needs_input parks (RE330)" do
    test "needs_input edges get no route at all; their sources are collected in parks" do
      {nodes, edges} = code_flow()
      %{routes: routes, parks: parks} = FlowLayout.layout(nodes, edges)

      park_idx = for {%{to: "needs_input"}, i} <- Enum.with_index(edges), do: i
      assert length(park_idx) == 8

      for i <- park_idx, do: refute(Map.has_key?(routes, i))
      assert map_size(routes) == length(edges) - length(park_idx)

      assert parks ==
               MapSet.new(~w(branch implement sync_fix final_fix smoke_fix acceptance_fix resync_fix post))
    end

    test "a flow with no needs_input edge has an empty parks set" do
      nodes = [%{key: "a", type: :agent}]
      edges = [%{from: "start", to: "a", on: nil}, %{from: "a", to: "done", on: :succeeded}]

      assert FlowLayout.layout(nodes, edges).parks == MapSet.new()
    end
  end
end
