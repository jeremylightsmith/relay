defmodule Relay.Repo.Migrations.CreateUserApiTokens do
  use Ecto.Migration

  def change do
    create table(:user_api_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :context, :string, null: false
      add :token_prefix, :string, null: false
      add :token_hash, :string, null: false
      add :last_four, :string, null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Deliberately NOT unique on user_id (unlike api_keys' one-key-per-board):
    # a user holds one token per signed-in device.
    create unique_index(:user_api_tokens, [:token_prefix])
    create index(:user_api_tokens, [:user_id])
  end
end
