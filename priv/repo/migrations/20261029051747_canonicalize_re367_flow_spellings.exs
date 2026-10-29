defmodule Hamaca.Repo.Migrations.CanonicalizeRe367FlowSpellings do
  use Ecto.Migration

  # RE487 — one idempotent re-sweep of the pre-RE367 `sub_tasks` flow-contract spellings, run
  # before the read-time alias (`Schemas.Flow.Node.normalize_legacy/1`) is deleted: from here on
  # a stored or pushed old spelling is refused, never rewritten. `RenameSubTasksToTasksInFlows`
  # did the first sweep by text `replace()`; this one edits the structured node maps, so it
  # touches only the four fields that carry the spellings.
  #
  # The pairs are a FROZEN copy of the RE367 alias table — the sanctioned exception to the
  # magic-value rule (a migration must replay identically forever, so it never calls app code).
  @contract_fields %{"sub_tasks" => "tasks"}
  @foreach_sources %{"card.sub_tasks" => "card.tasks"}
  # Ordered: `{sub_task_id}` first, though the closing brace already keeps `{sub_task}` disjoint.
  @placeholders [{"{sub_task_id}", "{task_id}"}, {"{sub_task}", "{task}"}]

  @tables ~w(flows flow_versions)

  def up, do: rewrite!(repo())

  # Nothing to restore: the old spellings were aliases of the canonical ones.
  def down, do: :ok

  @doc "The data rewrite `up` runs — also exactly what its test executes. Idempotent."
  def rewrite!(repo) do
    for table <- @tables, {id, nodes} <- rows(repo, table) do
      rewritten = Enum.map(nodes, &canonical_node/1)
      if rewritten != nodes, do: write!(repo, table, id, rewritten)
    end

    :ok
  end

  defp canonical_node(node) when is_map(node),
    do: Map.new(node, fn {key, value} -> {key, canonical(key, value)} end)

  defp canonical_node(node), do: node

  defp canonical(key, values) when key in ["reads", "writes"] and is_list(values),
    do: Enum.map(values, &Map.get(@contract_fields, &1, &1))

  defp canonical("foreach", source) when is_binary(source),
    do: Map.get(@foreach_sources, source, source)

  defp canonical("run", run) when is_binary(run),
    do:
      Enum.reduce(@placeholders, run, fn {legacy, canonical}, acc ->
        String.replace(acc, legacy, canonical)
      end)

  defp canonical(_key, value), do: value

  defp rows(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT id, nodes FROM #{table} WHERE jsonb_typeof(nodes) = 'array' ORDER BY id"
      )

    Enum.map(rows, fn [id, nodes] -> {id, nodes} end)
  end

  defp write!(repo, table, id, nodes),
    do: repo.query!("UPDATE #{table} SET nodes = $1 WHERE id = $2", [nodes, id])
end
