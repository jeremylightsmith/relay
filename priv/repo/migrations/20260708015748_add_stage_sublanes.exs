defmodule Relay.Repo.Migrations.AddStageSublanes do
  use Ecto.Migration

  def change do
    alter table(:stages) do
      add :lane, :string, null: false, default: "main"
      add :parent_id, references(:stages, on_delete: :delete_all)
    end

    create index(:stages, [:parent_id])
    # At most one review + one done child per parent.
    create unique_index(:stages, [:parent_id, :lane],
             where: "parent_id IS NOT NULL",
             name: :stages_parent_lane_index
           )
  end
end
