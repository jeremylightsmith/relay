defmodule Relay.Repo.Migrations.AddRejectToStageIdToStages do
  use Ecto.Migration

  def change do
    alter table(:stages) do
      add :reject_to_stage_id, references(:stages, on_delete: :nilify_all)
    end
  end
end
