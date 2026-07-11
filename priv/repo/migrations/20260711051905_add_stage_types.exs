defmodule Relay.Repo.Migrations.AddStageTypes do
  use Ecto.Migration

  def up do
    alter table(:stages) do
      add :type, :string
      add :ai_enabled, :boolean, default: false, null: false
    end

    flush()

    execute("""
    UPDATE stages SET type = CASE
      WHEN parent_id IS NOT NULL AND lane = 'review' THEN 'review'
      WHEN parent_id IS NOT NULL AND lane = 'done'   THEN 'done'
      WHEN approval_gate THEN 'review'
      WHEN name ILIKE '%review%' THEN 'review'
      WHEN category = 'unstarted' THEN 'queue'
      WHEN category = 'planning'  THEN 'planning'
      WHEN category = 'complete'  THEN 'done'
      ELSE 'work'
    END
    """)

    execute("UPDATE stages SET ai_enabled = (owner = 'ai' AND type IN ('work','planning'))")

    alter table(:stages) do
      modify :type, :string, null: false
    end

    drop_if_exists index(:stages, [:parent_id, :lane], name: :stages_parent_lane_index)

    create unique_index(:stages, [:parent_id, :type],
             where: "parent_id IS NOT NULL",
             name: :stages_parent_type_index
           )

    alter table(:stages) do
      remove :owner
      remove :lane
      remove :approval_gate
      remove :reject_to_stage_id
    end
  end

  def down do
    alter table(:stages) do
      add :owner, :string
      add :lane, :string, default: "main", null: false
      add :approval_gate, :boolean, default: false, null: false
      add :reject_to_stage_id, references(:stages, on_delete: :nilify_all)
    end

    drop_if_exists index(:stages, [:parent_id, :type], name: :stages_parent_type_index)
    create index(:stages, [:parent_id, :lane], name: :stages_parent_lane_index)

    alter table(:stages) do
      remove :type
      remove :ai_enabled
    end
  end
end
