defmodule RelayWeb.Api.RunJSONTest do
  use ExUnit.Case, async: true

  alias RelayWeb.Api.RunJSON
  alias Schemas.Run

  describe "index/1" do
    test "raises rather than silently returning [] when node_executions is not preloaded" do
      run = %Run{
        id: 1,
        flow_key: "flow",
        status: :running,
        node_executions: %Ecto.Association.NotLoaded{
          __field__: :node_executions,
          __owner__: Run,
          __cardinality__: :many
        }
      }

      assert_raise ArgumentError, ~r/node_executions/, fn ->
        RunJSON.index(%{runs: [run]})
      end
    end

    test "serializes a preloaded (possibly empty) list of node_executions" do
      run = %Run{id: 1, flow_key: "flow", status: :running, node_executions: []}

      assert %{data: [%{id: 1, node_executions: []}]} = RunJSON.index(%{runs: [run]})
    end
  end
end
