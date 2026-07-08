defmodule Relay.Repo.Migrations.AddDescriptionToStages do
  use Ecto.Migration

  def change do
    alter table(:stages) do
      add :description, :text
    end
  end
end
