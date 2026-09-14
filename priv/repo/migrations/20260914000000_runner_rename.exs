defmodule Relay.Repo.Migrations.RunnerRename do
  use Ecto.Migration

  # RE319 — "runner" is the only name for the machine process that claims node-jobs. A hard cut:
  # the table, every Postgres object named after it, the three name columns and the two stored
  # enum values all move in this one migration, so no row is left holding a value the schemas no
  # longer accept.

  @value_renames [
    {"parked_reason", "executor_gone", "runner_gone"},
    {"resume_refused_reason", "pinned_executor_absent", "pinned_runner_absent"}
  ]

  @doc "The stored `runs` enum values this migration renames, as `{column, old, new}`."
  def value_renames, do: @value_renames

  @doc "The data half of the migration in `direction` — also exactly what its test executes."
  def value_updates_sql(:up),
    do: for({column, old, new} <- @value_renames, do: update_sql(column, old, new))

  def value_updates_sql(:down),
    do: for({column, old, new} <- @value_renames, do: update_sql(column, new, old))

  defp update_sql(column, from, to),
    do: "UPDATE runs SET #{column} = '#{to}' WHERE #{column} = '#{from}'"

  def up do
    rename table(:executors), to: table(:runners)
    execute "ALTER SEQUENCE executors_id_seq RENAME TO runners_id_seq"
    execute "ALTER INDEX executors_board_id_name_index RENAME TO runners_board_id_name_index"
    execute "ALTER INDEX executors_last_heartbeat_index RENAME TO runners_last_heartbeat_index"
    execute rename_constraints_sql("runners", "executors_", "runners_")

    rename table(:runs), :pinned_executor_name, to: :pinned_runner_name
    rename table(:talk_sessions), :pinned_executor_name, to: :pinned_runner_name
    rename table(:node_jobs), :executor_name, to: :runner_name

    Enum.each(value_updates_sql(:up), &execute/1)
  end

  def down do
    Enum.each(value_updates_sql(:down), &execute/1)

    rename table(:node_jobs), :runner_name, to: :executor_name
    rename table(:talk_sessions), :pinned_runner_name, to: :pinned_executor_name
    rename table(:runs), :pinned_runner_name, to: :pinned_executor_name

    execute rename_constraints_sql("runners", "runners_", "executors_")
    execute "ALTER INDEX runners_last_heartbeat_index RENAME TO executors_last_heartbeat_index"
    execute "ALTER INDEX runners_board_id_name_index RENAME TO executors_board_id_name_index"
    execute "ALTER SEQUENCE runners_id_seq RENAME TO executors_id_seq"
    rename table(:runners), to: table(:executors)
  end

  # Postgres names the primary key, the board foreign key and (on 18+) every NOT NULL constraint
  # after the table, and `rename table` renames none of them. Renaming whatever exists by prefix
  # runs identically on a Postgres that names NOT NULLs and one that does not; renaming the pkey
  # constraint renames its index with it.
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
