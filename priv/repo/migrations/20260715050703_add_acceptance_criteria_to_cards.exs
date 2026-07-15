defmodule Relay.Repo.Migrations.AddAcceptanceCriteriaToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :acceptance_criteria, :text
    end
  end
end
