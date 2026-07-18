defmodule RelayWeb.FlowGraphComponentsTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.FlowGraphComponents
  alias RelayWeb.FlowLayout

  defp graph(nodes, edges, opts) do
    assigns =
      Map.merge(
        %{
          nodes: nodes,
          edges: edges,
          layout: FlowLayout.layout(nodes, edges),
          selected: nil,
          interactive?: false,
          node_states: %{},
          lands_on: "Review"
        },
        Map.new(opts)
      )

    render_component(&FlowGraphComponents.flow_graph/1, assigns)
  end

  defp one_node(type) do
    nodes = [%{key: "n", type: type, run: "go", model: nil, effort: nil}]
    edges = [%{from: "start", to: "n", on: nil}, %{from: "n", to: "done", on: :succeeded}]
    graph(nodes, edges, [])
  end

  describe "node shapes/colors by type (Relay Flow Editor.dc.html typeMeta, lines ~366-395)" do
    test "agent node: white fill, violet accent stripe + tag" do
      html = one_node(:agent)
      assert html =~ ~s(data-node="n")
      assert html =~ ~s(data-type="agent")
      # violet accent + AGENT tag
      assert html =~ "border-left:4px solid oklch(0.56 0.16 292)"
      assert html =~ "AGENT"
    end

    test "shell node: slate accent stripe + SHELL tag" do
      html = one_node(:shell)
      assert html =~ "border-left:4px solid oklch(0.55 0.02 255)"
      assert html =~ "SHELL"
    end

    test "gate node: amber diamond clip-path" do
      html = one_node(:gate)
      assert html =~ "clip-path:polygon(50% 0,100% 50%,50% 100%,0 50%)"
    end

    test "human node: blue hexagon clip-path" do
      html = one_node(:human)
      assert html =~ "clip-path:polygon(14% 0,86% 0,100% 50%,86% 100%,14% 100%,0 50%)"
    end

    test "parallel node: tinted teal fill" do
      html = one_node(:parallel)
      assert html =~ "oklch(0.985 0.02 195)"
      assert html =~ "PARALLEL"
    end
  end

  describe "edges and end pill" do
    test "failed edges render dashed; loop badge shows outcome · max N" do
      nodes = [%{key: "a", type: :agent, run: "x"}, %{key: "b", type: :agent, run: "y"}]

      edges = [
        %{from: "start", to: "a", on: nil},
        %{from: "a", to: "b", on: :succeeded},
        %{from: "b", to: "a", on: :failed, max_loops: 3},
        %{from: "b", to: "done", on: :succeeded}
      ]

      html = graph(nodes, edges, [])
      assert html =~ ~s(stroke-dasharray="5 4")
      assert html =~ "failed · max 3"
      # canonical vocabulary only — never the artboard's display labels
      refute html =~ "passed"
      refute html =~ "fixed"
    end

    test "end pill reads lands → <stage> in green" do
      html = one_node(:agent)
      assert html =~ "lands → Review"
      assert html =~ "oklch(0.42 0.10 155)"
    end
  end

  describe "interactivity" do
    test "interactive? false emits no phx-click; true emits node/edge click targets" do
      nodes = [%{key: "n", type: :agent, run: "go"}]
      edges = [%{from: "start", to: "n", on: nil}, %{from: "n", to: "done", on: :succeeded}]

      refute graph(nodes, edges, interactive?: false) =~ "phx-click"

      html = graph(nodes, edges, interactive?: true)
      assert html =~ ~s(phx-click="select_node")
      assert html =~ ~s(phx-value-key="n")
    end
  end
end
