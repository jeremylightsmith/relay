defmodule Relay.Repo.Migrations.AddKindAndCardToNodeJobs do
  use Ecto.Migration

  # RE268 / ADR 0009: `node_jobs` becomes the dispatch table for TWO dispatchers — the flow
  # engine (`kind: "node"`, always with a run) and a person typing in the Talk pane
  # (`kind: "talk"`, never with a run). `card_id` is set on EVERY row, backfilled from the run,
  # so board scoping is ONE join for both kinds instead of a coalesce over an outer join. The
  # same deliberate denormalisation `story_tasks.board_id` already uses (RE265).
  def up do
    alter table(:node_jobs) do
      add :kind, :string, null: false, default: "node"
      add :card_id, references(:cards, on_delete: :delete_all)
    end

    # `node_execution_id` follows `run_id`: a talk turn has neither.
    execute "ALTER TABLE node_jobs ALTER COLUMN run_id DROP NOT NULL"
    execute "ALTER TABLE node_jobs ALTER COLUMN node_execution_id DROP NOT NULL"

    execute "UPDATE node_jobs SET card_id = runs.card_id FROM runs WHERE node_jobs.run_id = runs.id"

    execute "ALTER TABLE node_jobs ALTER COLUMN card_id SET NOT NULL"

    create index(:node_jobs, [:card_id, :state])
    create index(:node_jobs, [:kind, :state])
  end

  def down do
    drop index(:node_jobs, [:kind, :state])
    drop index(:node_jobs, [:card_id, :state])

    execute "DELETE FROM node_jobs WHERE kind = 'talk'"
    execute "ALTER TABLE node_jobs ALTER COLUMN node_execution_id SET NOT NULL"
    execute "ALTER TABLE node_jobs ALTER COLUMN run_id SET NOT NULL"

    alter table(:node_jobs) do
      remove :card_id
      remove :kind
    end
  end
end
