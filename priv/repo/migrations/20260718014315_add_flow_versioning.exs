defmodule Relay.Repo.Migrations.AddFlowVersioning do
  use Ecto.Migration

  def up do
    alter table(:flows) do
      add :version, :integer, null: false, default: 1
    end

    create table(:flow_versions) do
      add :flow_id, references(:flows, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :isolation, :string, null: false
      add :nodes, :map
      add :edges, :map
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:flow_versions, [:flow_id, :version])

    # Backfill: every existing flow gets a v1 snapshot of its current definition, so the
    # "every flow has a snapshot for its current version" invariant holds from day one.
    execute("""
    INSERT INTO flow_versions (flow_id, version, isolation, nodes, edges, inserted_at)
    SELECT id, version, isolation, nodes, edges, (now() AT TIME ZONE 'utc')
    FROM flows
    """)
  end

  def down do
    drop table(:flow_versions)

    alter table(:flows) do
      remove :version
    end
  end
end
