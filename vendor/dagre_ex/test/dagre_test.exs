defmodule DagreTest do
  use ExUnit.Case, async: true

  alias Dagre.Layout

  defp n(id, width \\ 150, height \\ 56), do: %{id: id, width: width, height: height}

  test "lays out a two-node graph top to bottom, anchored at the origin" do
    layout =
      Dagre.layout(
        nodes: [n("a"), n("b", 118)],
        edges: [%{id: 0, from: "a", to: "b"}],
        ranksep: 68,
        nodesep: 24,
        edgesep: 12
      )

    assert %Layout{nodes: %{"a" => a, "b" => b}, edges: %{0 => edge}} = layout
    assert %{y: 0, width: 150, height: 56, rank: 0, order: 0} = a
    assert %{y: 124, width: 118, height: 56, rank: 1, order: 0} = b
    assert a.x + 75 == b.x + 59
    assert Enum.min([a.x, b.x]) == 0
    assert layout.size == {150, 180}
    assert edge == %{points: [{a.x + 75, 56}, {b.x + 59, 124}], label: nil, reversed?: false}
  end

  test "an empty graph has an empty layout" do
    assert Dagre.layout(nodes: [], edges: []) == %Layout{nodes: %{}, edges: %{}, size: {0, 0}}
  end

  test "a label gets its own rank, so ranks double and the label sits between the nodes" do
    layout =
      Dagre.layout(
        nodes: [n("a"), n("b")],
        edges: [%{id: :e, from: "a", to: "b", label: %{width: 92, height: 16}}],
        ranksep: 68
      )

    assert layout.nodes["a"].rank == 0
    assert layout.nodes["b"].rank == 2
    {_lx, ly} = layout.edges[:e].label
    assert ly > layout.nodes["a"].y + 56 and ly < layout.nodes["b"].y
  end

  test "a self-loop is routed off the node's right side, with its label beside it" do
    layout =
      Dagre.layout(
        nodes: [n("a")],
        edges: [%{id: :loop, from: "a", to: "a", label: %{width: 40, height: 16}}],
        edgesep: 10
      )

    %{x: x, y: y, width: w, height: h} = layout.nodes["a"]
    %{points: points, label: {lx, ly}, reversed?: false} = layout.edges[:loop]
    assert hd(points) == {x + w, y + div(h, 2) - div(h, 4)}
    assert List.last(points) == {x + w, y + div(h, 2) + div(h, 4)}
    assert Enum.all?(points, fn {px, _} -> px >= x + w end)
    assert lx - 20 >= x + w + 10
    assert ly == y + div(h, 2)
    assert layout.size == {150 + 10 + 10 + 40, 56}
  end

  test "accepts any term as a node or edge id" do
    layout = Dagre.layout(nodes: [n({:x, 1}), n(:y)], edges: [%{id: "edge", from: {:x, 1}, to: :y}])
    assert Map.keys(layout.nodes) |> Enum.sort() == Enum.sort([{:x, 1}, :y])
    assert Map.keys(layout.edges) == ["edge"]
  end

  test "rejects bad input" do
    assert_raise ArgumentError, ~r/rankdir :lr is not supported/, fn -> Dagre.layout(nodes: [], rankdir: :lr) end
    assert_raise ArgumentError, ~r/nodesep/, fn -> Dagre.layout(nodes: [], nodesep: -1) end
    assert_raise ArgumentError, ~r/unique/, fn -> Dagre.layout(nodes: [n(1), n(1)]) end

    assert_raise ArgumentError, ~r/unknown node/, fn ->
      Dagre.layout(nodes: [n(1)], edges: [%{id: 0, from: 1, to: 2}])
    end

    assert_raise ArgumentError, ~r/unique/, fn ->
      Dagre.layout(nodes: [n(1), n(2)], edges: [%{id: 0, from: 1, to: 2}, %{id: 0, from: 2, to: 1}])
    end

    assert_raise ArgumentError, ~r/needs :id, :width and :height/, fn -> Dagre.layout(nodes: [%{id: 1}]) end
  end
end
