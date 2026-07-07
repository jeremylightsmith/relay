defmodule Relay.Repo.Migrations.CreateCommentsAndActivities do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :actor_type, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:card_id, :inserted_at])
    create index(:comments, [:user_id])

    create table(:activities) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :meta, :map, null: false, default: %{}
      add :actor_type, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:activities, [:card_id, :inserted_at])
    create index(:activities, [:user_id])
  end
end
