defmodule Relay.Repo.Migrations.CreateCardOwners do
  use Ecto.Migration

  def change do
    create table(:card_owners) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :actor_type, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    # Two partial unique indexes because Postgres treats NULLs as distinct:
    # one guards duplicate (card, user) owners, the other duplicate agent rows.
    create unique_index(:card_owners, [:card_id, :actor_type, :user_id],
             where: "user_id IS NOT NULL",
             name: :card_owners_user_owner_index
           )

    create unique_index(:card_owners, [:card_id, :actor_type],
             where: "user_id IS NULL",
             name: :card_owners_agent_owner_index
           )

    create index(:card_owners, [:user_id])
  end
end
