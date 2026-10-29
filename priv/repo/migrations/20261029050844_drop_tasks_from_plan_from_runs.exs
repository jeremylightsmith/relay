defmodule Hamaca.Repo.Migrations.DropTasksFromPlanFromRuns do
  use Ecto.Migration

  # RE487 — the plan-parse task fallback is gone (its cards were seeded with real task rows by
  # `SeedTasksFromMonolithicPlans`), so nothing marks a run as fallback-seeded any more.
  def change do
    alter table(:runs) do
      remove :tasks_from_plan, :boolean, null: false, default: false
    end
  end
end
