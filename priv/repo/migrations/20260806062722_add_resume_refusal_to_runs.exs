defmodule Relay.Repo.Migrations.AddResumeRefusalToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      # When this run's resume STARTED being refused (nil = not currently refused), and which
      # cause the pure planner classified. Persisted rather than held in the scheduler's
      # GenServer state so the clock survives a deploy and is readable from `Runs.diagnose/3`
      # in another process (RE297).
      add :resume_refused_since, :utc_datetime
      add :resume_refused_reason, :string
    end

    # The reaper's sweep selects only stamped rows, which is a tiny minority of `runs`.
    create index(:runs, [:resume_refused_since], where: "resume_refused_since IS NOT NULL")
  end
end
