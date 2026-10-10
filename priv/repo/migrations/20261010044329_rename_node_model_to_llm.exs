defmodule Relay.Repo.Migrations.RenameNodeModelToLlm do
  use Ecto.Migration

  # RE433 — a flow node names a board agent (`llm`) instead of a bare Claude alias (`model`).
  # Rewrites both `flows.nodes` and the `flow_versions` snapshots that pin mid-run cards. An
  # unknown model RAISES rather than being dropped: nothing is silently lost.
  #
  # The table is a FROZEN copy of `Schemas.Flow.Node.legacy_models/0` — the one sanctioned
  # exception to the magic-value rule (a migration never calls app code that may change later).
  # It names the agents `CreateHarnessesAndAgents` seeded on every board just before this runs.
  @legacy_models %{
    "opus" => "Claude Opus",
    "sonnet" => "Claude Sonnet",
    "haiku" => "Claude Haiku"
  }

  @tables ~w(flows flow_versions)

  def up, do: rewrite!(repo())

  # `llm` → `model` only for the three legacy names; any other agent name has no `model` spelling.
  def down do
    reverse = Map.new(@legacy_models, fn {model, llm} -> {llm, model} end)

    for table <- @tables, {id, nodes} <- rows(repo(), table) do
      rewritten =
        Enum.map(nodes, fn
          %{"llm" => llm} = node when is_map_key(reverse, llm) ->
            node |> Map.delete("llm") |> Map.put("model", Map.fetch!(reverse, llm))

          node ->
            Map.delete(node, "llm")
        end)

      if rewritten != nodes, do: write!(repo(), table, id, rewritten)
    end
  end

  @doc "The data rewrite `up` runs — also exactly what its test executes."
  def rewrite!(repo) do
    for table <- @tables, {id, nodes} <- rows(repo, table) do
      rewritten = Enum.map(nodes, &rename_node(&1, table, id))
      if rewritten != nodes, do: write!(repo, table, id, rewritten)
    end

    :ok
  end

  defp rename_node(%{"model" => model} = node, table, id) do
    node = Map.delete(node, "model")

    cond do
      Map.get(node, "llm") ->
        node

      is_nil(model) ->
        node

      llm = Map.get(@legacy_models, model) ->
        Map.put(node, "llm", llm)

      true ->
        raise "#{table} row #{id}: node #{inspect(node["key"])} has model #{inspect(model)}, which has no agent"
    end
  end

  defp rename_node(node, _table, _id), do: node

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
