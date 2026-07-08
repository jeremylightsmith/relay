defmodule Relay.Repo.Migrations.AddApprovalGatesToStages do
  use Ecto.Migration

  def change do
    alter table(:stages) do
      add :approval_gate, :boolean, default: false, null: false
      add :reject_to_stage_id, references(:stages, on_delete: :nilify_all)
    end
  end
end
