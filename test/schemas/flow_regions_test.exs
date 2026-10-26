defmodule Schemas.FlowRegionsTest do
  @moduledoc """
  RE437 — `Schemas.Flow.regions/1`, `region/2` and `enclosing_region/2`: the ONE place a
  `fan_out` is paired with its `fan_in` and its branches are listed. Pure: no database.
  """
  use ExUnit.Case, async: true

  import Hamaca.FanOutFixtures

  alias Schemas.Flow

  # Scenario 19
  test "regions/1 lists panel's one region: its fan_in, max_parallel and branches in edge order" do
    assert Flow.regions(panel_flow()) == [
             %{
               fan_out: "fo",
               fan_in: "fi",
               max_parallel: 3,
               branches: [
                 %{key: "a", position: 0, nodes: ["a"]},
                 %{key: "b1", position: 1, nodes: ["b1", "b2"]},
                 %{key: "c", position: 2, nodes: ["c"]}
               ]
             }
           ]
  end

  test "regions/1 takes max_parallel from the fan_out when it is set" do
    flow = panel_flow(put_node(panel_nodes(), "fo", %{max_parallel: 2}), panel_edges())

    assert [%{max_parallel: 2}] = Flow.regions(flow)
  end

  test "regions/1 accepts any map with nodes and edges lists" do
    assert [%{fan_out: "fo", fan_in: "fi"}] = Flow.regions(%{nodes: panel_nodes(), edges: panel_edges()})
  end

  # Scenario 20
  test "enclosing_region/2 finds the region of a branch node and of the fan_in, and nil elsewhere" do
    flow = panel_flow()

    assert Flow.enclosing_region(flow, "b2").fan_out == "fo"
    assert Flow.enclosing_region(flow, "fi").fan_out == "fo"
    assert Flow.enclosing_region(flow, "fo") == nil
    assert Flow.enclosing_region(flow, "prep") == nil
    assert Flow.enclosing_region(flow, "after") == nil
  end

  test "region/2 returns the region a fan_out opens, and nil for any other key" do
    flow = panel_flow()

    assert Flow.region(flow, "fo").fan_in == "fi"
    assert Flow.region(flow, "a") == nil
  end

  test "regions/1 is empty for a flow with no fan_out" do
    nodes = [%{key: "work", type: :shell, run: "true"}]
    edges = [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]

    assert Flow.regions(panel_flow(nodes, edges)) == []
  end

  test "regions/1 reports a dead-ending branch's region with no fan_in, without raising" do
    flow = panel_flow(panel_nodes(), drop_edges(panel_edges(), "c", "fi"))

    assert [%{fan_out: "fo", fan_in: nil, branches: branches}] = Flow.regions(flow)
    assert %{key: "c", position: 2, nodes: ["c"]} = List.last(branches)
  end
end
