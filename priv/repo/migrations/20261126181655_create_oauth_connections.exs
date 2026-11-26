defmodule Hamaca.Repo.Migrations.CreateOauthConnections do
  use Ecto.Migration

  # RE519: the Claude connection — dynamically registered OAuth clients, the user × client
  # grant, single-use PKCE codes and hashed relaym_ access/refresh tokens.
  def change do
    create table(:oauth_clients) do
      add :client_id, :string, null: false
      add :client_name, :text
      add :redirect_uris, {:array, :text}, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_clients, [:client_id])

    create table(:oauth_grants) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :oauth_client_id, references(:oauth_clients, on_delete: :delete_all), null: false
      add :connected_at, :utc_datetime, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One grant per user × client: re-authorizing reconnects the same row.
    create unique_index(:oauth_grants, [:user_id, :oauth_client_id])
    create index(:oauth_grants, [:oauth_client_id])

    create table(:oauth_codes) do
      add :grant_id, references(:oauth_grants, on_delete: :delete_all), null: false
      add :code_hash, :string, null: false
      add :code_challenge, :string, null: false
      add :redirect_uri, :text, null: false
      add :resource, :text
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_codes, [:code_hash])
    create index(:oauth_codes, [:grant_id])

    create table(:oauth_tokens) do
      add :grant_id, references(:oauth_grants, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :token_prefix, :string, null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_tokens, [:token_prefix])
    create index(:oauth_tokens, [:grant_id])
  end
end
