defmodule Relay.Repo.Migrations.AddBlockedSinceToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :blocked_since, :utc_datetime, null: true
    end
  end
end
