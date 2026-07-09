defmodule Relay.Repo.Migrations.AddBranchAndPlanToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :branch, :string
      add :plan, :text
    end
  end
end
