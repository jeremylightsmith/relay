defmodule Relay.Repo.Migrations.AddArchivedAtToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :archived_at, :utc_datetime
    end

    create index(:cards, [:archived_at])
  end
end
