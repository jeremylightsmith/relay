# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Hamaca.Repo.Migrations.RenameParallelNodesToFanOut) do
  "priv/repo/migrations/*_rename_parallel_nodes_to_fan_out.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Hamaca.Migrations.RenameParallelNodesToFanOutTest do
  @moduledoc """
  RE437 — the never-run `parallel` node type became `fan_out`. `Ecto.Enum` can no longer load a
  stored `"parallel"`, so the migration rewrites `flows.nodes` and the `flow_versions` snapshots.
  Rows are written with raw SQL for the same reason.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo
  alias Hamaca.Repo.Migrations.RenameParallelNodesToFanOut, as: Migration

  # Scenario 23
  test "rewrites parallel to fan_out in flows and flow_versions, and a second run is a no-op" do
    flow = insert(:flow, nodes: [], edges: [])
    version_id = insert_version!(flow)
    legacy = [%{"key" => "p", "type" => "parallel"}, %{"key" => "s", "type" => "shell"}]
    rows = [{"flows", flow.id}, {"flow_versions", version_id}]

    for {table, id} <- rows, do: set_nodes!(table, id, legacy)

    Migration.rewrite!(Repo)

    for {table, id} <- rows do
      assert [%{"key" => "p", "type" => "fan_out"}, %{"key" => "s", "type" => "shell"}] = get_nodes!(table, id)
    end

    before = for {table, id} <- rows, do: get_nodes!(table, id)
    Migration.rewrite!(Repo)
    assert for({table, id} <- rows, do: get_nodes!(table, id)) == before
  end

  defp insert_version!(flow) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO flow_versions (flow_id, version, isolation, nodes, edges, inserted_at) VALUES ($1, 99, 'shared_clean', '[]', '[]', now()) RETURNING id",
        [flow.id]
      )

    id
  end

  defp set_nodes!(table, id, nodes), do: Repo.query!("UPDATE #{table} SET nodes = $1 WHERE id = $2", [nodes, id])

  defp get_nodes!(table, id) do
    %{rows: [[nodes]]} = Repo.query!("SELECT nodes FROM #{table} WHERE id = $1", [id])
    nodes
  end
end
