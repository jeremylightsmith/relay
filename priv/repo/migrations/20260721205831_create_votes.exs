defmodule Relay.Repo.Migrations.CreateVotes do
  use Ecto.Migration

  def change do
    create table(:votes) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:votes, [:card_id, :user_id])
    create index(:votes, [:card_id])
  end
end
