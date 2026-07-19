defmodule Relay.Repo.Migrations.AddVersionToExecutors do
  use Ecto.Migration

  def change do
    # Nullable on purpose (RLY-184): the legacy /api/board/heartbeat path and every
    # pre-RLY-184 executor send no version, and `nil` is the meaningful value "definitionally
    # behind" — not missing data.
    alter table(:executors) do
      add :version, :integer
    end
  end
end
