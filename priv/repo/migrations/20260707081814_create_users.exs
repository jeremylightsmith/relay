defmodule Relay.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :name, :string
      add :avatar_url, :string
      add :provider, :string, null: false
      add :provider_uid, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:provider_uid])
  end
end
