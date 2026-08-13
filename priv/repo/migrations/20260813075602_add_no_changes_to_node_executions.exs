defmodule Relay.Repo.Migrations.AddNoChangesToNodeExecutions do
  use Ecto.Migration

  def change do
    alter table(:node_executions) do
      # RE310: what the node CLAIMED — "succeeded, and no changes were needed". Stored
      # independent of the verdict, so a claim the guard rejected is still readable after the
      # fact as `no_changes: true` alongside `outcome: :failed`. Never cast; written by
      # Relay.Runs.finalize_job!/2 beside git_sha/session_id.
      add :no_changes, :boolean, null: false, default: false
    end
  end
end
