defmodule Relay.Repo.Migrations.CreateFlows do
  use Ecto.Migration

  def change do
    create table(:flows) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :enabled, :boolean, null: false, default: false
      add :isolation, :string, null: false
      add :pulls_from_stage_id, references(:stages, on_delete: :nilify_all)
      add :works_in_stage_id, references(:stages, on_delete: :nilify_all)
      add :lands_on_stage_id, references(:stages, on_delete: :nilify_all)
      add :nodes, :map
      add :edges, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:flows, [:board_id, :key])
    create index(:flows, [:pulls_from_stage_id])
    create index(:flows, [:works_in_stage_id])
    create index(:flows, [:lands_on_stage_id])

    # At most one *enabled* flow may pull from a given stage — two would race
    # for the same card. Disabled flows are exempt (partial index).
    create unique_index(:flows, [:board_id, :pulls_from_stage_id],
             where: "enabled",
             name: :flows_one_enabled_per_pulls_from_index
           )
  end
end
