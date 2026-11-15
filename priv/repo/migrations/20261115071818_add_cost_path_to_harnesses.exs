defmodule Hamaca.Repo.Migrations.AddCostPathToHarnesses do
  use Ecto.Migration

  # RE516 — every harness gets a nullable `cost_path`: a dot path to the session's cumulative USD
  # cost in the CLI's JSON events (nil = the CLI reports no cost). Each existing board's
  # `claude-code` harness is backfilled with `.total_cost_usd`.
  #
  # The key and path below are a FROZEN copy of the claude-code seed in
  # `Hamaca.Agents.seed_harnesses/0` — the one sanctioned exception to the magic-value rule: a
  # migration must replay identically forever, so it never calls app code that may change after
  # it ships.
  @key "claude-code"
  @cost_path ".total_cost_usd"

  def up do
    alter table(:harnesses) do
      add :cost_path, :string
    end

    flush()

    backfill!(repo())
  end

  def down do
    alter table(:harnesses) do
      remove :cost_path
    end
  end

  @doc """
  Gives every `claude-code` harness with no cost path the frozen `.total_cost_usd` — exactly what
  `up` runs. Any other harness, and a cost path somebody already set, is left alone, so it is
  idempotent.
  """
  def backfill!(repo) do
    %{num_rows: count} =
      repo.query!("UPDATE harnesses SET cost_path = $1 WHERE key = $2 AND cost_path IS NULL", [
        @cost_path,
        @key
      ])

    {count, nil}
  end
end
