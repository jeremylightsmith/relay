defmodule Relay.Repo.Migrations.CreateStoryMapTables do
  use Ecto.Migration

  # RE265: the story map's three board-scoped tables plus the three nilable card FKs.
  # `cards -> structure` is nilify_all: deleting structure UNMAPS cards, never deletes them.
  # `story_activities -> story_tasks` is delete_all: an activity owns its column of tasks.
  # No unique index on `position` — RE261's drag-reorder would otherwise need temporary
  # values to satisfy an invariant nobody needs.
  def change do
    create table(:story_activities) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:story_activities, [:board_id, :position])

    create table(:story_tasks) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :story_activity_id, references(:story_activities, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    # `board_id` is denormalized onto tasks (it is reachable through the activity) so every
    # read is a single board-scoped `where` and a cross-board task cannot be smuggled into a
    # query that only filters on board_id.
    create index(:story_tasks, [:board_id])
    create index(:story_tasks, [:story_activity_id, :position])

    create table(:releases) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:releases, [:board_id, :position])

    # Cards start fully UNMAPPED — all three nil. Existing rows are untouched, which is correct.
    alter table(:cards) do
      add :story_activity_id, references(:story_activities, on_delete: :nilify_all)
      add :story_task_id, references(:story_tasks, on_delete: :nilify_all)
      add :release_id, references(:releases, on_delete: :nilify_all)
    end

    create index(:cards, [:story_activity_id])
    create index(:cards, [:story_task_id])
    create index(:cards, [:release_id])
  end
end
