defmodule Relay.Repo.Migrations.AddCardSeqAndCreateCards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :card_seq, :integer, null: false, default: 0
    end

    create table(:cards) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :stage_id, references(:stages, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :position, :integer, null: false
      add :tag, :string
      add :ref_number, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cards, [:board_id, :ref_number])
    create index(:cards, [:stage_id, :position])
  end
end
