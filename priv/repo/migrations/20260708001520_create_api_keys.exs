defmodule Relay.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_prefix, :string, null: false
      add :token_hash, :string, null: false
      add :last_four, :string, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Single active key per board (MMF 08 decision) — going multi-key later
    # is just relaxing this to a plain index, not a reshape.
    create unique_index(:api_keys, [:board_id])
    create unique_index(:api_keys, [:token_prefix])
    create index(:api_keys, [:created_by_id])
  end
end
