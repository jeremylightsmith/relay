defmodule Relay.Repo.Migrations.AddStatusAndProgressToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :status, :string, null: false, default: "queued"
      add :progress, :integer
    end
  end
end
