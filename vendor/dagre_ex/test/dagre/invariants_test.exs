defmodule Dagre.InvariantsTest do
  @moduledoc """
  Machine-checkable properties of `Dagre.layout/1` output over a set of fixture
  graphs. Invariants 2–4 are the direct form of the three rendering complaints
  this library exists to fix: edges through node boxes, edges sharing a slot,
  and labels piled on top of each other.
  """
  use ExUnit.Case, async: true

  @opts [ranksep: 68, nodesep: 24, edgesep: 12]

  defp n(id, width \\ 150, height \\ 56), do: %{id: id, width: width, height: height}
  defp e(id, from, to), do: %{id: id, from: from, to: to}
  defp e(id, from, to, {w, h}), do: %{id: id, from: from, to: to, label: %{width: w, height: h}}

  defp random_dag(seed, count, weighted? \\ false) do
    :rand.seed(:exsss, {seed, seed * 7, seed * 13})
    nodes = for i <- 1..count, do: n(i, 20 + :rand.uniform(140), 20 + :rand.uniform(40))

    edges =
      for i <- 1..count, j <- (i + 1)..count//1, :rand.uniform() < 0.12 do
        edge = if :rand.uniform() < 0.4, do: e({i, j}, i, j, {30 + :rand.uniform(80), 16}), else: e({i, j}, i, j)
        if weighted?, do: Map.put(edge, :weight, :rand.uniform(3)), else: edge
      end

    %{nodes: nodes, edges: edges}
  end

  defp fixtures do
    %{
      chain: %{nodes: [n("a"), n("b"), n("c"), n("d")], edges: [e(1, "a", "b"), e(2, "b", "c"), e(3, "c", "d")]},
      diamond: %{
        nodes: [n("a"), n("b", 118), n("c"), n("d")],
        edges: [e(1, "a", "b"), e(2, "a", "c"), e(3, "b", "d"), e(4, "c", "d")]
      },
      back_edge: %{
        nodes: [n("a"), n("b"), n("c"), n("d")],
        edges: [e(1, "a", "b"), e(2, "b", "c"), e(3, "c", "d"), e(4, "d", "b", {92, 16})]
      },
      self_loop: %{
        nodes: [n("a"), n("b"), n("c")],
        edges: [e(1, "a", "b"), e(2, "b", "b", {110, 16}), e(3, "b", "c")]
      },
      back_edge_and_self_loop: %{
        nodes: [n("start"), n("work"), n("check", 118), n("done")],
        edges: [
          e(1, "start", "work"),
          e(2, "work", "work", {120, 16}),
          e(3, "work", "check"),
          e(4, "check", "work", {92, 16}),
          e(5, "check", "done")
        ]
      },
      fan_out_labelled: %{
        nodes: [n("s"), n("a"), n("b"), n("c"), n("t1", 60), n("t2", 60), n("t3", 60)],
        edges: [
          e(1, "s", "a", {92, 16}),
          e(2, "s", "b", {110, 16}),
          e(3, "s", "c", {60, 16}),
          e(4, "a", "t1"),
          e(5, "b", "t2"),
          e(6, "c", "t3")
        ]
      },
      long_edge: %{
        nodes: [n("a"), n("b"), n("c"), n("d"), n("e"), n("x", 118), n("y", 118)],
        edges: [
          e(1, "a", "b"),
          e(2, "b", "c"),
          e(3, "c", "d"),
          e(4, "d", "e"),
          e(5, "a", "e"),
          e(6, "a", "x"),
          e(7, "x", "y"),
          e(8, "y", "e")
        ]
      },
      review_loop: %{
        nodes: [n("implement"), n("spec_review"), n("quality_review"), n("gate", 118), n("final"), n("done", 90)],
        edges: [
          e(0, "implement", "spec_review", {92, 16}),
          e(1, "spec_review", "quality_review", {92, 16}),
          e(2, "quality_review", "gate", {60, 16}),
          e(3, "spec_review", "implement", {96, 16}),
          e(4, "quality_review", "implement", {96, 16}),
          e(5, "quality_review", "implement", {110, 16}),
          e(6, "gate", "implement", {110, 16}),
          e(7, "gate", "final"),
          e(8, "final", "done"),
          e(9, "implement", "implement", {100, 16})
        ]
      },
      # A heavy path a → b → c → d → e with light long edges and side nodes around it,
      # so light dummy chains contend with the path for alignment.
      heavy_path: %{
        nodes: [n("a"), n("b"), n("c", 117), n("d"), n("e"), n("x", 90), n("y"), n("z", 60)],
        edges: [
          %{id: 1, from: "a", to: "b", weight: 5},
          %{id: 2, from: "b", to: "c", weight: 5, label: %{width: 64, height: 16}},
          %{id: 3, from: "c", to: "d", weight: 5},
          %{id: 4, from: "d", to: "e", weight: 5},
          e(5, "x", "e"),
          e(6, "a", "y", {92, 16}),
          e(7, "y", "d"),
          e(8, "x", "c"),
          e(9, "b", "z"),
          e(10, "z", "e", {70, 16}),
          e(11, "e", "b", {96, 16})
        ]
      },
      random_dag: random_dag(1, 24),
      random_dag_2: random_dag(2, 30),
      weighted_random_dag: random_dag(3, 24, true),
      weighted_random_dag_2: random_dag(4, 36, true)
    }
  end

  defp lay_out(%{nodes: nodes, edges: edges}), do: Dagre.layout([nodes: nodes, edges: edges] ++ @opts)

  defp box(layout, id) do
    %{x: x, y: y, width: w, height: h} = layout.nodes[id]
    {x, y, w, h}
  end

  defp label_rects(layout, edges) do
    for %{id: id, label: %{width: w, height: h}} <- edges do
      {lx, ly} = layout.edges[id].label
      {id, {lx - div(w, 2), ly - div(h, 2), w, h}}
    end
  end

  # Strict: boxes that merely touch do not overlap.
  defp overlap?({ax, ay, aw, ah}, {bx, by, bw, bh}), do: ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah

  # Liang–Barsky against the rectangle's open interior: a segment that only
  # touches the border does not count.
  defp segment_hits_box?({x1, y1}, {x2, y2}, {bx, by, bw, bh}) do
    dx = x2 - x1
    dy = y2 - y1

    [{-dx, x1 - bx}, {dx, bx + bw - x1}, {-dy, y1 - by}, {dy, by + bh - y1}]
    |> Enum.reduce_while({0.0, 1.0}, fn
      {0, q}, acc -> if q > 0, do: {:cont, acc}, else: {:halt, :outside}
      {p, q}, {t0, t1} when p < 0 -> {:cont, {max(t0, q / p), t1}}
      {p, q}, {t0, t1} -> {:cont, {t0, min(t1, q / p)}}
    end)
    |> case do
      :outside -> false
      {t0, t1} -> t0 < t1
    end
  end

  defp inside?({x, y}, {bx, by, bw, bh}), do: x >= bx and x <= bx + bw and y >= by and y <= by + bh

  for name <- [
        :chain,
        :diamond,
        :back_edge,
        :self_loop,
        :back_edge_and_self_loop,
        :fan_out_labelled,
        :long_edge,
        :review_loop,
        :heavy_path,
        :random_dag,
        :random_dag_2,
        :weighted_random_dag,
        :weighted_random_dag_2
      ] do
    describe "#{name}" do
      setup do
        graph = Map.fetch!(fixtures(), unquote(name))
        %{graph: graph, layout: lay_out(graph)}
      end

      test "1. every non-reversed edge runs forward in rank, every reversed one backward", %{graph: g, layout: l} do
        for %{id: id, from: from, to: to} <- g.edges, from != to do
          if l.edges[id].reversed? do
            assert l.nodes[to].rank < l.nodes[from].rank, "reversed edge #{inspect(id)} does not run backward"
          else
            assert l.nodes[to].rank > l.nodes[from].rank, "edge #{inspect(id)} does not run forward"
          end
        end
      end

      test "2. no two node boxes overlap", %{graph: g, layout: l} do
        for a <- g.nodes, b <- g.nodes, a.id < b.id do
          refute overlap?(box(l, a.id), box(l, b.id)), "#{inspect(a.id)} overlaps #{inspect(b.id)}"
        end
      end

      test "3. no edge segment crosses a node box that is not one of its endpoints", %{graph: g, layout: l} do
        for %{id: id, from: from, to: to} <- g.edges,
            points = l.edges[id].points,
            {p, q} <- Enum.zip(points, tl(points)),
            node <- g.nodes,
            node.id not in [from, to] do
          refute segment_hits_box?(p, q, box(l, node.id)),
                 "edge #{inspect(id)} segment #{inspect({p, q})} crosses #{inspect(node.id)}"
        end
      end

      test "4. no label overlaps a node box or another label", %{graph: g, layout: l} do
        labels = label_rects(l, g.edges)

        for {id, rect} <- labels, node <- g.nodes do
          refute overlap?(rect, box(l, node.id)), "label of #{inspect(id)} overlaps node #{inspect(node.id)}"
        end

        for {a, ra} <- labels, {b, rb} <- labels, a < b do
          refute overlap?(ra, rb), "label of #{inspect(a)} overlaps label of #{inspect(b)}"
        end
      end

      test "5. the layout is deterministic", %{graph: g, layout: l} do
        again = lay_out(g)
        assert again == l
        assert :erlang.term_to_binary(again) == :erlang.term_to_binary(l)
      end

      test "6. every coordinate is a non-negative integer and lies inside size", %{graph: g, layout: l} do
        {sw, sh} = l.size
        assert is_integer(sw) and is_integer(sh)

        for node <- g.nodes do
          {x, y, w, h} = box(l, node.id)
          assert Enum.all?([x, y], &(is_integer(&1) and &1 >= 0))
          assert x + w <= sw and y + h <= sh, "#{inspect(node.id)} lies outside size"
        end

        for {_, rect} <- label_rects(l, g.edges), do: assert(fits?(rect, l.size))

        for {id, %{points: points}} <- l.edges, {x, y} <- points do
          assert is_integer(x) and is_integer(y) and x >= 0 and y >= 0, "edge #{inspect(id)} has #{inspect({x, y})}"
          assert x <= sw and y <= sh, "edge #{inspect(id)} point #{inspect({x, y})} lies outside size"
        end
      end

      test "7. every polyline starts at its source and ends at its target", %{graph: g, layout: l} do
        for %{id: id, from: from, to: to} <- g.edges do
          points = l.edges[id].points
          assert length(points) >= 2
          assert inside?(hd(points), box(l, from)), "edge #{inspect(id)} does not start at #{inspect(from)}"
          assert inside?(List.last(points), box(l, to)), "edge #{inspect(id)} does not end at #{inspect(to)}"
        end
      end
    end
  end

  defp fits?({x, y, w, h}, {sw, sh}), do: x >= 0 and y >= 0 and x + w <= sw and y + h <= sh

  test "the long_edge fixture really has an edge spanning three or more ranks" do
    l = lay_out(fixtures().long_edge)
    assert l.nodes["e"].rank - l.nodes["a"].rank >= 3
  end

  test "the fan_out_labelled fixture has three labelled edges leaving one node" do
    edges = fixtures().fan_out_labelled.edges
    assert edges |> Enum.filter(&(&1.from == "s" and Map.has_key?(&1, :label))) |> length() == 3
  end

  test "a back-edge and a self-loop: forward edges run forward and the reversed edge keeps the caller's direction" do
    g = fixtures().back_edge_and_self_loop
    l = lay_out(g)

    back = l.edges[4]
    assert back.reversed?
    assert l.nodes["check"].rank > l.nodes["work"].rank
    # caller's direction: check -> work, so the polyline starts at check and ends at work
    assert inside?(hd(back.points), box(l, "check"))
    assert inside?(List.last(back.points), box(l, "work"))

    loop = l.edges[2]
    refute loop.reversed?
    assert inside?(hd(loop.points), box(l, "work"))
    assert inside?(List.last(loop.points), box(l, "work"))

    for id <- [1, 3, 5], do: refute(l.edges[id].reversed?)
  end

  test "the heavy_path fixture's heavy edges are one vertical line" do
    l = lay_out(fixtures().heavy_path)
    [x] = ~w(a b c d e) |> Enum.map(&(l.nodes[&1].x + div(l.nodes[&1].width, 2))) |> Enum.uniq()

    for id <- 1..4, {px, _} <- l.edges[id].points, do: assert(px == x)
  end
end
