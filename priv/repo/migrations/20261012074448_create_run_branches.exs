defmodule Relay.Repo.Migrations.CreateRunBranches do
  use Ecto.Migration

  # RE437: one row per branch per region entry, keyed by the fan_out execution that opened it.
  # The FKs are circular (run_branches → node_executions and back), which Postgres allows: the
  # table is created first, then node_executions gains its nullable link.
  def change do
    create table(:run_branches) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :fan_out_execution_id, references(:node_executions, on_delete: :delete_all), null: false
      add :branch, :string, null: false
      add :position, :integer, null: false
      add :state, :string, null: false
      add :current_node, :string
      add :outcome, :string
      add :detail, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:run_branches, [:fan_out_execution_id, :branch])
    create index(:run_branches, [:run_id, :state])

    alter table(:node_executions) do
      add :run_branch_id, references(:run_branches, on_delete: :nilify_all)
    end

    create index(:node_executions, [:run_branch_id])
  end
end
