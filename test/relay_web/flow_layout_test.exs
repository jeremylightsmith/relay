defmodule RelayWeb.FlowLayoutTest do
  use ExUnit.Case, async: true

  alias RelayWeb.FlowLayout

  # atomize the DefaultLibrary Code flow into node/edge maps
  defp code_flow do
    flow = Enum.find(Relay.Flows.DefaultLibrary.all(), &(&1.key == "code"))
    {flow.nodes, flow.edges}
  end

  # grid cell for a key given a positions map, using the module's spacing constants
  defp cell({x, y}), do: {div(y - 34, 142), div(x - 8, 185)}

  describe "layout/2 on the default Code flow" do
    test "the success spine lays into serpentine rows of <= 6 columns" do
      {nodes, edges} = code_flow()
      %{positions: pos} = FlowLayout.layout(nodes, edges)

      # spine = branch → implement → ... following :succeeded edges, continuing
      # through quality_review's foreach_exhausted edge rather than looping
      # back via its foreach_remaining edge — 6 nodes fill row 0 exactly.
      assert {0, 0} = cell(pos["branch"])
      assert {0, 1} = cell(pos["implement"])
      assert {0, 4} = cell(pos["precommit"])
      assert {0, 5} = cell(pos["final_review"])
      # row 1 snakes back right→left: smoke sits at the far right (col 5)
      assert {1, 5} = cell(pos["smoke"])
      assert {1, _} = cell(pos["merge"])
    end

    test "fix nodes hang in a row below the spine, under their reviewer's column" do
      {nodes, edges} = code_flow()
      %{positions: pos} = FlowLayout.layout(nodes, edges)

      {frow, _} = cell(pos["final_fix"])
      {srow, _} = cell(pos["merge"])
      assert frow > srow

      # final_fix hangs under precommit's column (precommit → final_fix on :failed)
      {_, pcol} = cell(pos["precommit"])
      {_, fcol} = cell(pos["final_fix"])
      assert fcol == pcol
    end

    test "route kinds classify loop-backs as arcs and the start/done edges specially" do
      {nodes, edges} = code_flow()
      %{routes: routes} = FlowLayout.layout(nodes, edges)

      idx = fn from, to -> Enum.find_index(edges, &(&1.from == from and &1.to == to)) end

      assert routes[idx.("start", "branch")] == :enter
      assert routes[idx.("merge", "done")] == :exit
      # spec_review → implement (failed) points backward on the same row → arc
      assert routes[idx.("spec_review", "implement")] == :arc
      # branch → implement (succeeded), row-adjacent → horizontal
      assert routes[idx.("branch", "implement")] == :horizontal
    end

    test "unreachable nodes park in a row below everything, deterministically" do
      nodes = [%{key: "a", type: :agent}, %{key: "b", type: :agent}, %{key: "orphan", type: :shell}]
      edges = [%{from: "start", to: "a", on: nil}, %{from: "a", to: "done", on: :succeeded}]

      %{positions: pos} = FlowLayout.layout(nodes, edges)
      {orow, _} = cell(pos["orphan"])
      {arow, _} = cell(pos["a"])
      assert orow > arow
    end

    # W13: a `foreach` loop head's two guarded edges both carry `on: :succeeded`
    # (RLY-139) — the spine must keep moving forward through the one that
    # doesn't loop back, not dead-end at the first-listed edge.
    test "a node with two guarded :succeeded edges continues the spine through the non-looping one" do
      nodes = [
        %{key: "head", type: :agent, foreach: "card.sub_tasks"},
        %{key: "tail", type: :gate}
      ]

      edges = [
        %{from: "start", to: "head", on: nil},
        %{from: "head", to: "head", on: :succeeded, when: :foreach_remaining},
        %{from: "head", to: "tail", on: :succeeded, when: :foreach_exhausted},
        %{from: "tail", to: "done", on: :succeeded}
      ]

      %{positions: pos} = FlowLayout.layout(nodes, edges)
      assert {0, 0} = cell(pos["head"])
      assert {0, 1} = cell(pos["tail"])
    end
  end
end
