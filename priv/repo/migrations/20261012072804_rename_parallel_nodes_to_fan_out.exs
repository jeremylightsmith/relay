defmodule Hamaca.Repo.Migrations.RenameParallelNodesToFanOut do
  use Ecto.Migration

  # RE437 — the never-run `parallel` node type became the `fan_out` control node. Once
  # `:parallel` left `Schemas.Flow.Node`'s type enum, `Ecto.Enum` can no longer load a stored
  # `"parallel"`, so this rewrites both `flows.nodes` and the `flow_versions` snapshots that pin
  # mid-run cards. `Schemas.Flow.Node.normalize_legacy/1` covers attrs on their way IN; this
  # covers what is already stored.
  #
  # The alias is a FROZEN copy of the one in `Schemas.Flow.Node` — the sanctioned exception to
  # the magic-value rule (a migration never calls app code that may change later).
  @legacy_type "parallel"
  @canonical_type "fan_out"

  @tables ~w(flows flow_versions)

  def up, do: rewrite!(repo())

  # `fan_out` → `parallel`. Lossy only for a node authored as `fan_out` after this ran, which
  # the older code could not run either.
  def down, do: retype!(repo(), @canonical_type, @legacy_type)

  @doc "The data rewrite `up` runs — also exactly what its test executes. Idempotent."
  def rewrite!(repo), do: retype!(repo, @legacy_type, @canonical_type)

  defp retype!(repo, from, to) do
    for table <- @tables, {id, nodes} <- rows(repo, table) do
      rewritten =
        Enum.map(nodes, fn
          %{"type" => ^from} = node -> %{node | "type" => to}
          node -> node
        end)

      if rewritten != nodes, do: write!(repo, table, id, rewritten)
    end

    :ok
  end

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
