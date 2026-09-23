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

  # edge paths are the SVG paths whose `d` starts with "M " (a space); the arrowhead marker
  # paths in <defs> start "M0,0" (no space), so this filter keeps only real edges, in order.
  defp edge_ds(html), do: ~r/d="(M [^"]*)"/ |> Regex.scan(html) |> Enum.map(fn [_, d] -> d end)
  defp edge_d(html, idx), do: Enum.at(edge_ds(html), idx)
  defp path_nums(d), do: ~r/-?\d+/ |> Regex.scan(d) |> Enum.map(fn [n] -> String.to_integer(n) end)
  defp path_xs(d), do: d |> path_nums() |> Enum.take_every(2)
  defp vertical?(d), do: d |> path_xs() |> Enum.uniq() |> length() == 1
  defp max_x(d), do: d |> path_xs() |> Enum.max()

  # mirrors RelayWeb.FlowLayout's @row_h (the vertical pitch between spine rows).
  @row_h 124

  defp path_ys(d), do: d |> path_nums() |> Enum.drop_every(2)

  defp code_flow do
    flow = Enum.find(Relay.Flows.DefaultLibrary.all(), &(&1.key == "code"))
    {flow.nodes, flow.edges}
  end

  # an agent that can park, feeding a gate that cannot.
  defp parked_flow do
    nodes = [%{key: "a", type: :agent, run: "x"}, %{key: "g", type: :gate, run: "mix test"}]

    edges = [
      %{from: "start", to: "a", on: nil},
      %{from: "a", to: "g", on: :succeeded},
      %{from: "a", to: "needs_input", on: :failed},
      %{from: "g", to: "done", on: :succeeded}
    ]

    {nodes, edges}
  end

  defp badge_tag(html, key) do
    [tag] = Regex.run(~r/<span[^>]*data-park="#{key}"[^>]*>/, html)
    tag
  end

  defp label_top(html, idx) do
    [_, y] = Regex.run(~r/data-edge="#{idx}"[^>]*?top:(-?\d+)px/, html)
    String.to_integer(y)
  end

  describe "node shapes/colors by type (Relay Flow Editor.dc.html typeMeta, lines ~366-395)" do
    test "agent node: white fill, violet accent stripe + tag" do
      html = one_node(:agent)
      assert html =~ ~s(data-node="n")
      assert html =~ ~s(data-type="agent")
      # violet accent + AGENT tag
      assert html =~ "border-left:4px solid var(--color-secondary)"
      assert html =~ "AGENT"
    end

    test "shell node: slate accent stripe + SHELL tag" do
      html = one_node(:shell)
      assert html =~ "border-left:4px solid color-mix(in oklab, var(--color-base-content) 60%, var(--color-base-100))"
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
      assert html =~ "color-mix(in oklab, var(--color-accent) 5%, var(--color-base-100))"
      assert html =~ "PARALLEL"
    end
  end

  describe "agent node label surfaces the bound subagent" do
    test "an agent node stacks agent · model · effort in the sub-label" do
      nodes = [%{key: "n", type: :agent, run: "go", model: "opus", effort: "high", agent: "plan-implementer"}]
      edges = [%{from: "start", to: "n", on: nil}, %{from: "n", to: "done", on: :succeeded}]
      html = graph(nodes, edges, [])
      assert html =~ "plan-implementer · opus · high"
    end

    test "a generic agent node (no `agent` field) still shows model · effort" do
      nodes = [%{key: "n", type: :agent, run: "go", model: "sonnet", effort: "high"}]
      edges = [%{from: "start", to: "n", on: nil}, %{from: "n", to: "done", on: :succeeded}]
      html = graph(nodes, edges, [])
      assert html =~ "sonnet · high"
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
      assert html =~ "color-mix(in oklab, var(--color-success) 45%, var(--color-base-content))"
    end

    test "foreach guard edges render human wording appended to the outcome" do
      nodes = [%{key: "q", type: :agent, run: "review"}, %{key: "impl", type: :agent, run: "do"}]

      edges = [
        %{from: "start", to: "q", on: nil},
        %{from: "q", to: "impl", on: :succeeded, when: :foreach_remaining},
        %{from: "q", to: "done", on: :succeeded, when: :foreach_exhausted}
      ]

      html = graph(nodes, edges, [])
      assert html =~ "succeeded · while tasks remain"
      assert html =~ "succeeded · all tasks done"
      # the raw guard atom never reaches the pill
      refute html =~ "foreach_remaining"
      refute html =~ "foreach_exhausted"
    end

    # RLY-186 regression: the pill used to be pinned at a hardcoded top:150px/left:2px, which the
    # new vertical layout drew a spine node right on top of. It must instead be anchored to the
    # layout's done_point so it lands below the last spine node, clear of every node.
    test "end pill is anchored below done_point, not a fixed coordinate" do
      nodes = [
        %{key: "a", type: :agent, run: "one", model: nil, effort: nil},
        %{key: "b", type: :agent, run: "two", model: nil, effort: nil}
      ]

      edges = [
        %{from: "start", to: "a", on: nil},
        %{from: "a", to: "b", on: :succeeded},
        %{from: "b", to: "done", on: :succeeded}
      ]

      layout = FlowLayout.layout(nodes, edges)
      {_dx, done_y} = layout.done_point
      html = graph(nodes, edges, [])

      [_, top] = Regex.run(~r/top:(-?\d+)px[^>]*>\s*<span[^>]*>\s*<\/span>\s*lands →/, html)
      assert String.to_integer(top) == done_y + 8
      refute html =~ "top:150px"
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

  describe "vertical edge routing (RLY-186)" do
    test "a forward spine edge is drawn as a vertical line" do
      nodes = [%{key: "a", type: :agent, run: "x"}, %{key: "b", type: :agent, run: "y"}]

      edges = [
        %{from: "start", to: "a", on: nil},
        %{from: "a", to: "b", on: :succeeded},
        %{from: "b", to: "done", on: :succeeded}
      ]

      html = graph(nodes, edges, [])
      # edge index 1 is a -> b (:drop)
      assert vertical?(edge_d(html, 1))
    end

    test "a back-edge routes out beyond every node into the right-hand gutter" do
      nodes = [%{key: "a", type: :agent, run: "x"}, %{key: "b", type: :agent, run: "y"}]

      edges = [
        %{from: "start", to: "a", on: nil},
        %{from: "a", to: "b", on: :succeeded},
        %{from: "b", to: "a", on: :failed, max_loops: 2},
        %{from: "b", to: "done", on: :succeeded}
      ]

      layout = FlowLayout.layout(nodes, edges)
      html = graph(nodes, edges, [])
      # widest node right edge (both agents, width 150)
      node_right = layout.positions |> Map.values() |> Enum.map(fn {x, _y} -> x + 150 end) |> Enum.max()
      # edge index 2 is the b -> a back-edge (:gutter)
      assert max_x(edge_d(html, 2)) > node_right
    end

    test "the two arrows of a rework detour carry labels at different y positions" do
      nodes = [%{key: "gate", type: :gate, run: "mix precommit"}, %{key: "fix", type: :agent, run: "fix"}]

      edges = [
        %{from: "start", to: "gate", on: nil},
        %{from: "gate", to: "fix", on: :failed, max_loops: 2},
        %{from: "fix", to: "gate", on: :succeeded},
        %{from: "gate", to: "done", on: :succeeded}
      ]

      html = graph(nodes, edges, [])
      # index 1 = gate -> fix (:side_out, offset above); index 2 = fix -> gate (:side_back, below)
      assert label_top(html, 1) != label_top(html, 2)
    end

    test "node_size/1 is the single source of node box dimensions" do
      assert FlowLayout.node_size(:gate) == {118, 76}
      assert FlowLayout.node_size(:agent) == {150, 56}
      assert FlowLayout.node_size(:human) == {150, 56}
    end
  end

  describe "zero-node (scratch) flow" do
    test "renders a bare start → done edge as a single straight connector without raising" do
      html = graph([], [%{from: "start", to: "done", on: nil}], [])

      ds = edge_ds(html)
      assert length(ds) == 1
      assert vertical?(hd(ds))
    end
  end

  describe "needs_input edges are not drawn (RE330)" do
    test "the Code flow emits no path or label for any needs_input edge" do
      {nodes, edges} = code_flow()
      html = graph(nodes, edges, [])

      park_idx = for {%{to: "needs_input"}, i} <- Enum.with_index(edges), do: i
      assert length(park_idx) == 8

      assert length(edge_ds(html)) == length(edges) - length(park_idx)

      labelled =
        ~r/data-edge="(\d+)"/ |> Regex.scan(html) |> Enum.map(fn [_, i] -> String.to_integer(i) end)

      assert labelled != []
      for i <- park_idx, do: refute(i in labelled)
    end

    # The original bug: every needs_input edge was routed to done_point, so each one drew a
    # straight line from its source down the spine column through every node box below it. Any
    # edge that is not out in the right-hand gutter connects adjacent rows (or stays on one row),
    # so its vertical extent must never exceed one row pitch.
    test "no non-gutter edge path spans more than one row" do
      {nodes, edges} = code_flow()
      layout = FlowLayout.layout(nodes, edges)
      html = graph(nodes, edges, [])
      types = Map.new(nodes, &{&1.key, &1.type})

      node_right =
        layout.positions
        |> Enum.map(fn {k, {x, _y}} -> x + elem(FlowLayout.node_size(types[k]), 0) end)
        |> Enum.max()

      for d <- edge_ds(html), max_x(d) <= node_right do
        ys = path_ys(d)
        span = Enum.max(ys) - Enum.min(ys)
        assert span <= @row_h, "edge path #{d} spans #{span}px vertically (> one row, #{@row_h}px)"
      end
    end
  end

  describe "park badge (RE330)" do
    test "every Code flow node with a needs_input edge carries exactly one badge" do
      {nodes, edges} = code_flow()
      html = graph(nodes, edges, [])

      badged = ~r/data-park="([^"]+)"/ |> Regex.scan(html) |> Enum.map(fn [_, k] -> k end)
      expected = for %{from: from, to: "needs_input"} <- edges, do: from

      assert length(badged) == 8
      assert Enum.sort(badged) == Enum.sort(expected)
    end

    test "a flow with no needs_input edge renders no badge" do
      refute one_node(:agent) =~ "data-park"
    end

    test "the badge is a warning-coloured pause glyph with hover and screen-reader text" do
      {nodes, edges} = parked_flow()
      html = graph(nodes, edges, [])
      tag = badge_tag(html, "a")

      assert tag =~ ~s(title="Can park for human input")
      assert tag =~ ~s(aria-label="Can park for human input")
      assert tag =~ "border:1.5px solid var(--color-warning)"
      assert html =~ "hero-pause-circle"
      refute html =~ ~s(data-park="g")
    end

    test "the badge is not interactive, even in the interactive editor" do
      {nodes, edges} = parked_flow()
      tag = nodes |> graph(edges, interactive?: true) |> badge_tag("a")

      refute tag =~ "phx-click"
      refute tag =~ "phx-value"
    end

    test "the badge straddles the node box's top-right corner" do
      {nodes, edges} = parked_flow()
      layout = FlowLayout.layout(nodes, edges)
      {x, y} = layout.positions["a"]
      {w, _h} = FlowLayout.node_size(:agent)
      tag = nodes |> graph(edges, []) |> badge_tag("a")

      assert tag =~ "left:#{x + w - 12}px;top:#{y - 9}px;"
    end
  end
end
