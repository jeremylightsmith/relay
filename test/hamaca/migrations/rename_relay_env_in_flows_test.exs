# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Hamaca.Repo.Migrations.RenameRelayEnvInFlows) do
  "priv/repo/migrations/*_rename_relay_env_in_flows.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Hamaca.Migrations.RenameRelayEnvInFlowsTest do
  @moduledoc """
  RE482 — the runner stops exporting the `RELAY_<suffix>` env names, so every stored shell node
  `run` that reads one (`"$RELAY_PLAN"` in the Code flow's `branch` node) is rewritten to the
  `HAMACA_<suffix>` name, in both `flows.nodes` and the `flow_versions` snapshots.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo
  alias Hamaca.Repo.Migrations.RenameRelayEnvInFlows, as: Migration

  @agent_node %{
    "key" => "implement",
    "type" => "agent",
    "agent" => "plan-implementer",
    "expects_commits" => true,
    "reads" => [],
    "writes" => []
  }

  setup do
    {:ok, board} = Hamaca.Boards.create_board(insert(:user), %{name: "RE482 env rewrite board"})
    flow = Hamaca.Flows.get_flow!(board, "code")
    version = Repo.get_by!(Schemas.FlowVersion, flow_id: flow.id, version: flow.version)
    %{rows: [{"flows", flow.id}, {"flow_versions", version.id}]}
  end

  # Scenario 1
  test "rewrites whole RELAY_<exported suffix> names in flows and flow_versions, leaving the agent node byte-identical",
       %{rows: rows} do
    for {table, id} <- rows,
        do: set_nodes!(table, id, [shell(~s(x > "$RELAY_PLAN" && echo ${RELAY_REF} $RELAY_NODE_SCRATCH)), @agent_node])

    agent_before = Enum.map(rows, fn {table, id} -> node_text!(table, id, 1) end)

    assert Migration.rewrite!(Repo) == :ok

    for {table, id} <- rows do
      assert [%{"run" => run}, agent] = get_nodes!(table, id)
      assert run == ~s(x > "$HAMACA_PLAN" && echo ${HAMACA_REF} $HAMACA_NODE_SCRATCH)
      assert agent == @agent_node
    end

    assert Enum.map(rows, fn {table, id} -> node_text!(table, id, 1) end) == agent_before
  end

  # Scenario 2
  test "leaves a partial suffix, an unexported name, the {relay} placeholder and ~/.relay alone", %{rows: rows} do
    run = "$RELAY_PLANNER $RELAY_URL {relay} ~/.relay"
    for {table, id} <- rows, do: set_nodes!(table, id, [shell(run)])

    assert Migration.rewrite!(Repo) == :ok

    for {table, id} <- rows, do: assert([%{"run" => ^run}] = get_nodes!(table, id))
  end

  # Scenario 3
  test "a second run updates zero rows and leaves the first run's result", %{rows: rows} do
    for {table, id} <- rows, do: set_nodes!(table, id, [shell(~s(test -s "$RELAY_PLAN"))])

    assert Migration.rewrite!(Repo) == :ok
    first = Enum.map(rows, fn {table, id} -> {get_nodes!(table, id), row_version!(table, id)} end)

    assert Migration.rewrite!(Repo) == :ok
    # `xmin` changes on every UPDATE of a row, so an unchanged one proves no row was written.
    assert Enum.map(rows, fn {table, id} -> {get_nodes!(table, id), row_version!(table, id)} end) == first
    assert [[%{"run" => ~s(test -s "$HAMACA_PLAN")}] | _] = Enum.map(first, &elem(&1, 0))
  end

  defp shell(run),
    do: %{"key" => "branch", "type" => "shell", "run" => run, "expects_commits" => false, "reads" => [], "writes" => []}

  defp set_nodes!(table, id, nodes), do: Repo.query!("UPDATE #{table} SET nodes = $1 WHERE id = $2", [nodes, id])

  defp get_nodes!(table, id) do
    %{rows: [[nodes]]} = Repo.query!("SELECT nodes FROM #{table} WHERE id = $1", [id])
    nodes
  end

  defp node_text!(table, id, index) do
    %{rows: [[text]]} = Repo.query!("SELECT (nodes -> #{index})::text FROM #{table} WHERE id = $1", [id])
    text
  end

  defp row_version!(table, id) do
    %{rows: [[xmin]]} = Repo.query!("SELECT xmin::text FROM #{table} WHERE id = $1", [id])
    xmin
  end
end
