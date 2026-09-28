defmodule Relay.Repo.Migrations.AddBodyToSubTasks do
  use Ecto.Migration

  # RE355 — a task's own markdown body, so a plan's per-task content can live on its row.
  # Nullable, no default, no backfill: existing rows simply have no body.
  def change do
    alter table(:sub_tasks) do
      add :body, :text
    end
  end
end
