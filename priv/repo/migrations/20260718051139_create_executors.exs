defmodule Relay.Repo.Migrations.CreateExecutors do
  use Ecto.Migration

  def change do
    create table(:executors) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :host, :string
      add :interval, :integer, null: false, default: 30
      add :capacity, :map, null: false, default: %{}
      add :last_heartbeat, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:executors, [:board_id, :name], name: :executors_board_id_name_index)
    create index(:executors, [:last_heartbeat])
  end
end
