defmodule Relay.Repo.Migrations.AddRetriesToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :retries, :integer, null: false, default: 0
    end
  end
end
