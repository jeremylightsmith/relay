defmodule Relay.Repo.Migrations.AddSubTaskIdToNodeExecutions do
  use Ecto.Migration

  def change do
    alter table(:node_executions) do
      add :sub_task_id, references(:sub_tasks, on_delete: :nilify_all)
    end

    create index(:node_executions, [:sub_task_id])
  end
end
