# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Hamaca.Repo.Migrations.CanonicalizeRe367FlowSpellings) do
  "priv/repo/migrations/*_canonicalize_re367_flow_spellings.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Hamaca.Migrations.CanonicalizeRe367FlowSpellingsTest do
  @moduledoc """
  RE487 — one idempotent re-sweep of stored `flows` / `flow_versions` nodes for the pre-RE367
  `sub_tasks` spellings, run before `Schemas.Flow.Node.normalize_legacy/1` is deleted. Rows are
  written and read with raw SQL: `Ecto.Enum` cannot load a stored `"sub_tasks"`.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo
  alias Hamaca.Repo.Migrations.CanonicalizeRe367FlowSpellings, as: Migration

  @legacy_node %{
    "key" => "implement",
    "type" => "agent",
    "run" => "Do {sub_task_id} ({sub_task}) — the sub_tasks table stays",
    "foreach" => "card.sub_tasks",
    "reads" => ["sub_tasks"],
    "writes" => ["plan", "sub_tasks"],
    "expects_commits" => false
  }

  @gate_node %{
    "key" => "after",
    "type" => "gate",
    "run" => "true",
    "expects_commits" => false,
    "reads" => [],
    "writes" => []
  }

  setup do
    user = insert(:user)
    {:ok, board} = Hamaca.Boards.create_board(user, %{name: "RE367 re-sweep board"})
    flow = Hamaca.Flows.get_flow!(board, "code")
    version = Repo.get_by!(Schemas.FlowVersion, flow_id: flow.id, version: flow.version)
    %{board: board, flow: flow, version: version}
  end

  # Scenario 1
  test "rewrite!/1 canonicalizes the RE367 spellings in flows and flow_versions", %{flow: flow, version: version} do
    rows = [{"flows", flow.id}, {"flow_versions", version.id}]
    for {table, id} <- rows, do: set_nodes!(table, id, [@legacy_node, @gate_node])

    assert Migration.rewrite!(Repo) == :ok

    for {table, id} <- rows do
      assert [implement, gate] = get_nodes!(table, id)

      assert implement == %{
               @legacy_node
               | "foreach" => "card.tasks",
                 "reads" => ["tasks"],
                 "writes" => ["plan", "tasks"],
                 "run" => "Do {task_id} ({task}) — the sub_tasks table stays"
             }

      assert gate == @gate_node
    end
  end

  # Scenario 2
  test "rewrite!/1 leaves a canonical flow untouched, and a second run is a no-op", %{board: board} do
    plan = Hamaca.Flows.get_flow!(board, "plan")
    nodes_before = get_nodes!("flows", plan.id)
    updated_at_before = get_updated_at!(plan.id)

    assert Migration.rewrite!(Repo) == :ok
    assert get_nodes!("flows", plan.id) == nodes_before
    assert get_updated_at!(plan.id) == updated_at_before

    assert Migration.rewrite!(Repo) == :ok
    assert get_nodes!("flows", plan.id) == nodes_before
    assert get_updated_at!(plan.id) == updated_at_before
  end

  defp set_nodes!(table, id, nodes), do: Repo.query!("UPDATE #{table} SET nodes = $1 WHERE id = $2", [nodes, id])

  defp get_nodes!(table, id) do
    %{rows: [[nodes]]} = Repo.query!("SELECT nodes FROM #{table} WHERE id = $1", [id])
    nodes
  end

  defp get_updated_at!(id) do
    %{rows: [[updated_at]]} = Repo.query!("SELECT updated_at FROM flows WHERE id = $1", [id])
    updated_at
  end
end
