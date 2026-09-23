defmodule Relay.Repo.Migrations.AddReleaseRequestsToRunners do
  use Ecto.Migration

  # RE337: card refs a human asked this runner to release (free the worktree, keep the run).
  # Persisted rather than held in memory because the request must survive a deploy and be seen by
  # whichever app machine answers the runner's next heartbeat.
  def change do
    alter table(:runners) do
      add :release_requests, {:array, :string}, null: false, default: []
    end
  end
end
