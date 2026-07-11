defmodule Relay.Repo.Migrations.DropCardsProgress do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      remove :progress, :integer
    end
  end
end
