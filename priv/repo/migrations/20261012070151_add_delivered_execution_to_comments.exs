defmodule Relay.Repo.Migrations.AddDeliveredExecutionToComments do
  use Ecto.Migration

  # RE358 — the Steer now receipt: the node execution a `:steer` comment was delivered to, set
  # when that execution's agent job is claimed with the steer in its guidance. Nullable: every
  # existing comment, every non-steer comment and every steer not yet delivered has none. Nilified
  # if the execution is ever deleted, so a receipt never blocks run cleanup.
  def change do
    alter table(:comments) do
      add :delivered_execution_id, references(:node_executions, on_delete: :nilify_all)
    end

    create index(:comments, [:delivered_execution_id])
  end
end
