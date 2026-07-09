defmodule Relay.Repo.Migrations.AddRejectionToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :rejection, :map
    end
  end
end
