defmodule Relay.Repo.Migrations.AddCollapsedByDefaultToStages do
  use Ecto.Migration

  def change do
    alter table(:stages) do
      add :collapsed_by_default, :boolean, default: false, null: false
    end
  end
end
