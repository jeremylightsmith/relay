defmodule Relay.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  def change do
    create table(:attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :storage_key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:attachments, [:card_id, :inserted_at])
  end
end
