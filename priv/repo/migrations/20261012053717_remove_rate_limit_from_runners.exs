defmodule Hamaca.Repo.Migrations.RemoveRateLimitFromRunners do
  use Ecto.Migration

  # RE436: a runner no longer pauses as a whole. Each harness's usage reading — and its pause —
  # rides that harness's `runners.harnesses` entry, and "rate limited" is derived from them
  # (every installed harness paused). The runner-wide RE320 pause column is retired. `down`
  # restores the empty column; the readings it held are transient (each cleared by the next
  # heartbeat), so nothing is lost.
  def up do
    alter table(:runners) do
      remove :rate_limit
    end
  end

  def down do
    alter table(:runners) do
      add :rate_limit, :map
    end
  end
end
