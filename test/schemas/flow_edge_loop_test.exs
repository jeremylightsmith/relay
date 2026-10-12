defmodule Schemas.FlowEdgeLoopTest do
  use ExUnit.Case, async: true

  alias Schemas.Flow.Edge

  describe "loop?/1" do
    test "an edge with a positive max_loops is a loop (struct or plain map)" do
      assert Edge.loop?(%Edge{from: "a", to: "b", max_loops: 3})
      assert Edge.loop?(%{from: "a", to: "b", max_loops: 1})
    end

    test "nil, 0, or a missing max_loops is not a loop" do
      refute Edge.loop?(%Edge{from: "a", to: "b"})
      refute Edge.loop?(%{from: "a", to: "b", max_loops: nil})
      refute Edge.loop?(%{from: "a", to: "b", max_loops: 0})
      refute Edge.loop?(%{from: "a", to: "b"})
    end
  end
end
