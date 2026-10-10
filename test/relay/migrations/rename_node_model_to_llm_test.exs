# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.RenameNodeModelToLlm) do
  "priv/repo/migrations/*_rename_node_model_to_llm.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.RenameNodeModelToLlmTest do
  @moduledoc """
  RE433 — stored flow nodes move from `model` (a bare Claude alias) to `llm` (a board agent's
  name), in both `flows.nodes` and the `flow_versions` snapshots. An unknown model raises: nothing
  is silently dropped.
  """
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Repo.Migrations.RenameNodeModelToLlm, as: Migration

  @shell_node %{
    "key" => "s",
    "type" => "shell",
    "run" => "true",
    "expects_commits" => false,
    "reads" => [],
    "writes" => []
  }

  setup do
    flow = insert(:flow, nodes: [], edges: [])
    version = insert_version!(flow)
    %{flow: flow, version: version}
  end

  # Scenario 18
  test "rewrites model to llm in flows and flow_versions, leaving other nodes byte-identical",
       %{flow: flow, version: version} do
    legacy = [%{"key" => "x", "type" => "agent", "model" => "haiku"}, @shell_node]
    set_nodes!("flows", flow.id, legacy)
    set_nodes!("flow_versions", version.id, legacy)
    shell_before = node_text!("flows", flow.id, 1)

    Migration.rewrite!(Repo)

    for {table, id} <- [{"flows", flow.id}, {"flow_versions", version.id}] do
      assert [%{"key" => "x", "type" => "agent", "llm" => "Claude Haiku"} = agent, @shell_node] = get_nodes!(table, id)
      refute Map.has_key?(agent, "model")
    end

    assert node_text!("flows", flow.id, 1) == shell_before
  end

  test "raises on an unknown model, naming the table, the row, the node and the model", %{flow: flow} do
    set_nodes!("flows", flow.id, [%{"key" => "x", "type" => "agent", "model" => "gpt-4"}])

    error = assert_raise RuntimeError, fn -> Migration.rewrite!(Repo) end
    assert error.message =~ "flows"
    assert error.message =~ "#{flow.id}"
    assert error.message =~ ~s("x")
    assert error.message =~ ~s("gpt-4")
  end

  defp insert_version!(flow) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO flow_versions (flow_id, version, isolation, nodes, edges, inserted_at) VALUES ($1, 99, 'shared_clean', '[]', '[]', now()) RETURNING id",
        [flow.id]
      )

    %{id: id}
  end

  defp set_nodes!(table, id, nodes), do: Repo.query!("UPDATE #{table} SET nodes = $1 WHERE id = $2", [nodes, id])

  defp get_nodes!(table, id) do
    %{rows: [[nodes]]} = Repo.query!("SELECT nodes FROM #{table} WHERE id = $1", [id])
    nodes
  end

  defp node_text!(table, id, index) do
    %{rows: [[text]]} = Repo.query!("SELECT (nodes -> #{index})::text FROM #{table} WHERE id = $1", [id])
    text
  end
end
