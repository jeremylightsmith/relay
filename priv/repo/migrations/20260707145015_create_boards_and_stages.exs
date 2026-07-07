defmodule Relay.Repo.Migrations.CreateBoardsAndStages do
  use Ecto.Migration

  def change do
    create table(:boards) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false, default: "My board"
      add :slug, :string, null: false
      add :key, :string, null: false, default: "RLY"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:boards, [:slug])
    create index(:boards, [:owner_id])

    create table(:stages) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false
      add :category, :string, null: false
      add :owner, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stages, [:board_id, :position])
  end
end
