defmodule Relay.Repo.Migrations.AddArchivedAtToBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :archived_at, :utc_datetime
    end
  end
end
