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

  # Every drawn, non-self-loop edge end as `{node_key, point}`: the first point on the edge's
  # source, the last on its target.
  defp edge_ends(edges, layout) do
    for {edge, i} <- Enum.with_index(edges),
        Map.has_key?(layout.routes, i),
        edge.from != edge.to,
        points = layout.routes[i].points,
        end_ <- [{edge.from, hd(points)}, {edge.to, List.last(points)}],
        do: end_
  end

  # A point on a gate's diamond outline: |dx|/(w/2) + |dy|/(h/2) = 1 about the box centre,
  # multiplied through by w·h/2 and allowed one pixel of integer rounding in y.
  defp on_diamond?({px, py}, {x, y, w, h}) do
    dx = abs(2 * px - (2 * x + w))
    dy = abs(2 * py - (2 * y + h))
    abs(dx * h + dy * w - w * h) <= 2 * w
  end

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

    test "no two edge ends on the same node coincide (RE340)" do
      for flow <- library() do
        layout = FlowLayout.layout(flow.nodes, flow.edges)

        for {key, points} <- flow.edges |> edge_ends(layout) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
            key != "start" do
          assert length(Enum.uniq(points)) == length(points),
                 "#{flow.key}: two edge ends on #{key} coincide: #{inspect(points)}"
        end
      end
    end

    test "every edge end lies on its node's visible border, within the port span (RE340)" do
      {branchy_nodes, branchy_edges} = branchy_flow()

      for {nodes, edges} <- Enum.map(library(), &{&1.nodes, &1.edges}) ++ [{branchy_nodes, branchy_edges}] do
        layout = FlowLayout.layout(nodes, edges)
        boxes = boxes(nodes, layout)
        types = Map.new(nodes, &{&1.key, node_type(&1)})

        for {key, {px, py} = point} <- edge_ends(edges, layout), Map.has_key?(boxes, key) do
          {_x, y, _w, h} = box = boxes[key]
          {left, right} = FlowLayout.port_span(types[key], box)
          assert px in left..right, "#{key}: end #{inspect(point)} outside port span #{left}..#{right}"

          if types[key] == :gate,
            do: assert(on_diamond?(point, box), "gate #{key}: end #{inspect(point)} is off the diamond"),
            else: assert(py in [y, y + h], "#{key}: end #{inspect(point)} is off the top/bottom border")
        end
      end
    end

    test "laying out the same flow twice yields equal results" do
      for flow <- library() do
        assert FlowLayout.layout(flow.nodes, flow.edges) == FlowLayout.layout(flow.nodes, flow.edges),
               "#{flow.key}: layout is not deterministic"
      end
    end
  end

  describe "layout/2 contract" do
    test "is total over a transient editor working copy: duplicate keys and dangling edges" do
      nodes = [%{key: "a", type: :agent}, %{key: "a", type: :agent}, %{key: "b", type: :shell}]

      edges = [
        %{from: "start", to: "a", on: nil},
        %{from: "a", to: "ghost", on: "ok"},
        %{from: "ghost", to: "b", on: "ok"},
        %{from: "a", to: "b", on: "ok"},
        %{from: "b", to: "done", on: "ok"}
      ]

      layout = FlowLayout.layout(nodes, edges)
      assert layout.positions |> Map.keys() |> Enum.sort() == ["a", "b"]
      assert layout.routes |> Map.keys() |> Enum.sort() == [0, 3, 4]
    end

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

    test "every entry edge leaves start_point and every exit edge lands on done's top border" do
      {branchy_nodes, branchy_edges} = branchy_flow()

      for {nodes, edges} <- Enum.map(library(), &{&1.nodes, &1.edges}) ++ [{branchy_nodes, branchy_edges}] do
        layout = FlowLayout.layout(nodes, edges)
        {_done_x, done_y} = layout.done_point
        exits = for {%{to: "done"}, i} <- Enum.with_index(edges), do: List.last(layout.routes[i].points)

        for {edge, i} <- Enum.with_index(edges),
            edge.from == "start",
            do: assert(hd(layout.routes[i].points) == layout.start_point)

        # A sole exit edge lands on done_point itself; several spread along done's top border.
        if length(exits) == 1, do: assert(exits == [layout.done_point])
        for {_x, y} <- exits, do: assert(y == done_y)
        assert length(Enum.uniq(exits)) == length(exits)
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

  describe "port spreading (RE340)" do
    test "a single edge on a side keeps its centre anchor: a plain chain is unchanged" do
      nodes = [%{key: "a", type: :agent}, %{key: "b", type: :agent}]

      edges = [
        %{from: "start", to: "a", on: nil},
        %{from: "a", to: "b", on: :succeeded},
        %{from: "b", to: "done", on: :succeeded}
      ]

      layout = FlowLayout.layout(nodes, edges)
      %{"a" => {ax, ay}, "b" => {bx, by}} = layout.positions
      {w, h} = FlowLayout.node_size(:agent)

      assert layout.routes[1].points == [{ax + div(w, 2), ay + h}, {bx + div(w, 2), by}]
    end

    test "a gate's out-edges get their own ports on the diamond's lower faces, left branch on the left" do
      nodes = [%{key: "g", type: :gate}, %{key: "a", type: :agent}, %{key: "b", type: :agent}]

      edges = [
        %{from: "start", to: "g", on: nil},
        %{from: "g", to: "a", on: :succeeded},
        %{from: "g", to: "b", on: :failed},
        %{from: "a", to: "done", on: :succeeded},
        %{from: "b", to: "done", on: :succeeded}
      ]

      layout = FlowLayout.layout(nodes, edges)
      {gx, gy, gw, gh} = gate = boxes(nodes, layout)["g"]
      {left_i, right_i} = if elem(layout.positions["a"], 0) < elem(layout.positions["b"], 0), do: {1, 2}, else: {2, 1}
      {lx, ly} = left_port = hd(layout.routes[left_i].points)
      {rx, ry} = right_port = hd(layout.routes[right_i].points)

      assert lx < gx + div(gw, 2) and gx + div(gw, 2) < rx
      assert ly < gy + gh and ry < gy + gh
      assert on_diamond?(left_port, gate) and on_diamond?(right_port, gate)
    end

    test "a loop-back edge lands on its target's bottom apart from that target's own out-edge" do
      nodes = [%{key: "a", type: :agent}, %{key: "b", type: :agent}]

      edges = [
        %{from: "start", to: "a", on: nil},
        %{from: "a", to: "b", on: :succeeded},
        %{from: "b", to: "a", on: :failed},
        %{from: "b", to: "done", on: :succeeded}
      ]

      layout = FlowLayout.layout(nodes, edges)
      {_ax, ay} = layout.positions["a"]
      {_w, h} = FlowLayout.node_size(:agent)
      {_, out_y} = out_port = hd(layout.routes[1].points)
      {_, back_y} = back_port = List.last(layout.routes[2].points)

      assert out_y == ay + h and back_y == ay + h
      refute out_port == back_port
    end

    test "port_span/2 insets each shape so a port never lands on a corner or a slanted face" do
      assert FlowLayout.port_span(:agent, {0, 0, 150, 56}) == {18, 132}
      assert FlowLayout.port_span(:done, {0, 0, 180, 40}) == {18, 162}
      assert FlowLayout.port_span(:human, {0, 0, 150, 56}) == {27, 123}
      assert FlowLayout.port_span(:gate, {0, 0, 118, 76}) == {29, 89}
      assert FlowLayout.port_span(:start, {0, 0, 16, 16}) == {8, 8}
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
