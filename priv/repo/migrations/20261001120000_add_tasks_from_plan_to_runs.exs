defmodule Relay.Repo.Migrations.AddTasksFromPlanToRuns do
  use Ecto.Migration

  # RE368 — true when this run's tasks were seeded by the legacy plan-parse fallback, so
  # `relay audit` can report a planner that has not migrated to `relay tasks add`.
  # Not null with a false default: every existing run predates the fact and stays unmarked.
  def change do
    alter table(:runs) do
      add :tasks_from_plan, :boolean, null: false, default: false
    end
  end
end
