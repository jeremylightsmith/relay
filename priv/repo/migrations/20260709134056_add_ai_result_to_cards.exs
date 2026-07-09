defmodule Relay.Repo.Migrations.AddAiResultToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :ai_result, :map
    end
  end
end
