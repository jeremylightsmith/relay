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

      # spine = branch → implement → ... following :succeeded edges
      assert {0, 0} = cell(pos["branch"])
      assert {0, 1} = cell(pos["implement"])
      assert {0, 5} = cell(pos["precommit"])
      # row 1 snakes back right→left: final_review sits under precommit (col 5)
      assert {1, 5} = cell(pos["final_review"])
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
  end
end
