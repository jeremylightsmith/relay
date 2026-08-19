defmodule Relay.Repo.Migrations.AddHeldToExecutors do
  use Ecto.Migration

  def change do
    alter table(:executors) do
      # RE311: the per-card worktrees this executor declares it HOLDS, as
      # [%{"ref" => ref, "state" => state}]. Written by the HEARTBEAT ONLY, with the same
      # nil-means-untouched discipline as `capacity` and `capabilities` — the claim's `held` is
      # request-scoped and is never persisted. This is what lets the runners view count real
      # occupancy (a bound-but-idle, talk-attached or retained tree is invisible to the
      # active-job count) and what `Relay.Runs.diagnose/3` reads to name who holds a slot.
      add :held, {:array, :map}, null: false, default: []
    end
  end
end
