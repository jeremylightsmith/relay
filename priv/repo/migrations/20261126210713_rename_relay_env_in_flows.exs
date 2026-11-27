defmodule Hamaca.Repo.Migrations.RenameRelayEnvInFlows do
  use Ecto.Migration

  # RE482 — the runner stops exporting the `RELAY_<suffix>` env names (it exports only
  # `HAMACA_<suffix>`, as every runner ≥ v94 already did alongside them), so every stored shell
  # node `run` that reads one — the Code flow's `branch` node writes `"$RELAY_PLAN"` — is rewritten
  # to the `HAMACA_` name, in `flows.nodes` and the `flow_versions` snapshots.
  #
  # The suffixes are a FROZEN copy of the runner's `ENV_EXPORTED` — the sanctioned exception to
  # the magic-value rule (a migration must replay identically forever, so it never calls app
  # code). Only whole names match: `RELAY_PLANNER` is left alone, and so are names the runner
  # never exported (`RELAY_URL`), the `{relay}` placeholder and the `~/.relay` machine path.
  @suffixes ~w(NODE_SCRATCH NODE_OUTCOME PLAN REF BRANCH BASE WORKTREE CACHE_DIR)
  @pattern Regex.compile!("\\bRELAY_(#{Enum.join(@suffixes, "|")})(?![A-Za-z0-9_])")

  @tables ~w(flows flow_versions)

  def up, do: rewrite!(repo())

  # Nothing to restore: every runner the server still accepts exports the `HAMACA_` names.
  def down, do: :ok

  @doc "The data rewrite `up` runs — also exactly what its test executes. Idempotent."
  def rewrite!(repo) do
    for table <- @tables, {id, nodes} <- rows(repo, table) do
      rewritten = Enum.map(nodes, &rename_node/1)
      if rewritten != nodes, do: write!(repo, table, id, rewritten)
    end

    :ok
  end

  defp rename_node(%{"run" => run} = node) when is_binary(run),
    do: %{node | "run" => Regex.replace(@pattern, run, "HAMACA_\\1")}

  defp rename_node(node), do: node

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
