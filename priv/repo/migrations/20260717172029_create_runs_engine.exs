defmodule Relay.Repo.Migrations.CreateRunsEngine do
  use Ecto.Migration

  def change do
    create table(:runs) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :flow_id, references(:flows, on_delete: :nilify_all)
      add :flow_key, :string, null: false
      add :status, :string, null: false
      add :parked_reason, :string
      add :current_node, :string
      add :context, :map, null: false, default: %{}
      add :failure_detail, :text
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:runs, [:card_id])
    create index(:runs, [:flow_id])

    # At most one ACTIVE (running or parked) run per card — race-proof.
    create unique_index(:runs, [:card_id],
             where: "status IN ('running','parked')",
             name: :runs_one_active_per_card_index
           )

    create table(:node_executions) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :node_key, :string, null: false
      add :visit, :integer, null: false
      add :attempt, :integer, null: false
      add :outcome, :string
      add :detail, :text
      add :failure_signature, :string
      add :git_sha, :string
      add :session_id, :string
      add :cost, :decimal
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:node_executions, [:run_id])

    create table(:node_jobs) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :node_execution_id, references(:node_executions, on_delete: :delete_all), null: false
      add :node_key, :string, null: false
      add :state, :string, null: false
      add :executor_name, :string
      add :payload, :map, null: false, default: %{}
      add :claimed_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:node_jobs, [:run_id])
    create index(:node_jobs, [:node_execution_id])
    create index(:node_jobs, [:run_id, :state])
  end
end
