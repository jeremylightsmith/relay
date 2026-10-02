# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.RenameSubTasksToTasksInFlows) do
  "priv/repo/migrations/*_rename_sub_tasks_to_tasks_in_flows.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.RenameSubTasksToTasksInFlowsTest do
  @moduledoc """
  RE367 — stored flows move from the legacy `sub_tasks` flow-contract spellings to `tasks`, in
  both `flows.nodes` and the `flow_versions.nodes` snapshots that pin mid-run cards. Without it a
  stored `"sub_tasks"` in `reads`/`writes` would fail `Ecto.Enum` on load.
  """
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Repo.Migrations.RenameSubTasksToTasksInFlows, as: Migration

  @legacy_node %{
    "key" => "implement",
    "type" => "agent",
    "run" =>
      ~s|Implement task {sub_task_id} ("{sub_task}"): `{relay} task show {ref} {sub_task_id}` — the sub_tasks table stays|,
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
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Migration board"})
    flow = Relay.Flows.get_flow!(board, "code")
    version = Repo.get_by!(Schemas.FlowVersion, flow_id: flow.id, version: flow.version)
    %{board: board, flow: flow, version: version}
  end

  test "every pair maps a legacy spelling to a different canonical one" do
    for {legacy, canonical} <- Migration.renames() do
      assert legacy =~ "sub_task"
      refute canonical =~ "sub_task"
    end
  end

  test "up rewrites flows and flow_versions to canonical; down restores the legacy text",
       %{flow: flow, version: version} do
    set_nodes!("flows", flow.id, [@legacy_node, @gate_node])
    set_nodes!("flow_versions", version.id, [@legacy_node, @gate_node])

    Enum.each(Migration.rewrite_sql(:up), &Repo.query!/1)

    implement = Enum.find(Repo.get!(Schemas.Flow, flow.id).nodes, &(&1.key == "implement"))
    assert implement.foreach == "card.tasks"
    assert implement.reads == [:tasks]
    assert implement.writes == [:plan, :tasks]

    assert implement.run ==
             ~s|Implement task {task_id} ("{task}"): `{relay} task show {ref} {task_id}` — the sub_tasks table stays|

    snapshot = Repo.get!(Schemas.FlowVersion, version.id)
    assert Enum.find(snapshot.nodes, &(&1.key == "implement")) == implement
    assert Enum.find(get_nodes!("flows", flow.id), &(&1["key"] == "after")) == @gate_node

    Enum.each(Migration.rewrite_sql(:down), &Repo.query!/1)

    assert get_nodes!("flows", flow.id) == [@legacy_node, @gate_node]
    assert get_nodes!("flow_versions", version.id) == [@legacy_node, @gate_node]
  end

  test "up leaves an already-canonical flow untouched", %{board: board} do
    plan = Relay.Flows.get_flow!(board, "plan")
    before = get_nodes!("flows", plan.id)

    Enum.each(Migration.rewrite_sql(:up), &Repo.query!/1)

    assert get_nodes!("flows", plan.id) == before
  end

  defp set_nodes!(table, id, nodes), do: Repo.query!("UPDATE #{table} SET nodes = $1 WHERE id = $2", [nodes, id])

  defp get_nodes!(table, id) do
    %{rows: [[nodes]]} = Repo.query!("SELECT nodes FROM #{table} WHERE id = $1", [id])
    nodes
  end
end
