defmodule Relay.Repo.Migrations.CreateSubTasks do
  use Ecto.Migration

  def change do
    create table(:sub_tasks) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :done, :boolean, null: false, default: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:sub_tasks, [:card_id])
  end
end
