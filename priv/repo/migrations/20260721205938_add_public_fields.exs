defmodule Relay.Repo.Migrations.AddPublicFields do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :public_enabled, :boolean, null: false, default: false
      add :public_intake_stage_id, references(:stages, on_delete: :nilify_all)
    end

    alter table(:cards) do
      add :public_description, :text
    end
  end
end
