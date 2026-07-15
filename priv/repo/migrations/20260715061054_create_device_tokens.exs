defmodule Relay.Repo.Migrations.CreateDeviceTokens do
  use Ecto.Migration

  def change do
    create table(:device_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :platform, :string, null: false, default: "ios"
      add :last_registered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # A device token is unique to a device + app install: re-registering after an
    # account switch must re-point the existing row, not duplicate it.
    create unique_index(:device_tokens, [:token])
    create index(:device_tokens, [:user_id])
  end
end
