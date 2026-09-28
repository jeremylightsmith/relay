defmodule Relay.Repo.Migrations.StoryMapStepRename do
  use Ecto.Migration

  # RE354 — the story-map concept "Task" is now "Step", freeing "task" for a card's own work
  # items. A hard cut: the table, every Postgres object named after it, the card FK column and
  # the one persisted view key all move in this migration. `foreign_key_constraint/2` matches
  # the default `<table>_<column>_fkey` name, so a constraint left on the old name would turn
  # an FK error changeset into a raise.

  @view_key_rename {"hide_tasks", "hide_steps"}

  @doc "The `boards.story_map_view` key this migration renames, as `{old, new}`."
  def view_key_rename, do: @view_key_rename

  @doc "The data half of the migration in `direction` — also exactly what its test executes."
  def view_key_sql(:up) do
    {old, new} = @view_key_rename
    move_key_sql(old, new)
  end

  def view_key_sql(:down) do
    {old, new} = @view_key_rename
    move_key_sql(new, old)
  end

  defp move_key_sql(from, to) do
    """
    UPDATE boards
    SET story_map_view = (story_map_view - '#{from}') || jsonb_build_object('#{to}', story_map_view -> '#{from}')
    WHERE story_map_view ? '#{from}'
    """
  end

  def up do
    rename table(:story_tasks), to: table(:story_steps)
    execute "ALTER SEQUENCE story_tasks_id_seq RENAME TO story_steps_id_seq"
    execute "ALTER INDEX story_tasks_board_id_index RENAME TO story_steps_board_id_index"

    execute "ALTER INDEX story_tasks_story_activity_id_position_index RENAME TO story_steps_story_activity_id_position_index"

    execute rename_constraints_sql("story_steps", "story_tasks_", "story_steps_")

    rename table(:cards), :story_task_id, to: :story_step_id
    execute "ALTER INDEX cards_story_task_id_index RENAME TO cards_story_step_id_index"

    execute "ALTER TABLE cards RENAME CONSTRAINT cards_story_task_id_fkey TO cards_story_step_id_fkey"

    execute view_key_sql(:up)
  end

  def down do
    execute view_key_sql(:down)

    execute "ALTER TABLE cards RENAME CONSTRAINT cards_story_step_id_fkey TO cards_story_task_id_fkey"
    execute "ALTER INDEX cards_story_step_id_index RENAME TO cards_story_task_id_index"
    rename table(:cards), :story_step_id, to: :story_task_id

    execute rename_constraints_sql("story_steps", "story_steps_", "story_tasks_")

    execute "ALTER INDEX story_steps_story_activity_id_position_index RENAME TO story_tasks_story_activity_id_position_index"

    execute "ALTER INDEX story_steps_board_id_index RENAME TO story_tasks_board_id_index"
    execute "ALTER SEQUENCE story_steps_id_seq RENAME TO story_tasks_id_seq"
    rename table(:story_steps), to: table(:story_tasks)
  end

  # Postgres names the primary key, both foreign keys and (on 18+) every NOT NULL constraint
  # after the table, and `rename table` renames none of them. Renaming whatever exists by prefix
  # runs identically on a Postgres that names NOT NULLs and one that does not; renaming the pkey
  # constraint renames its index with it. (Same helper as `RunnerRename`.)
  defp rename_constraints_sql(table, from_prefix, to_prefix) do
    """
    DO $$
    DECLARE c record;
    BEGIN
      FOR c IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = '#{table}'::regclass AND starts_with(conname, '#{from_prefix}')
      LOOP
        EXECUTE format('ALTER TABLE #{table} RENAME CONSTRAINT %I TO %I',
                       c.conname, '#{to_prefix}' || substr(c.conname, #{String.length(from_prefix) + 1}));
      END LOOP;
    END $$;
    """
  end
end
