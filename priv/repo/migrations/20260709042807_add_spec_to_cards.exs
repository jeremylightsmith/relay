defmodule Relay.Repo.Migrations.AddSpecToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :spec, :text
    end
  end
end
