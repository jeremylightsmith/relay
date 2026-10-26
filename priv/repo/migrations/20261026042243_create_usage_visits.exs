defmodule Relay.Repo.Migrations.CreateUsageVisits do
  use Ecto.Migration

  # RE475 — signed-in usage, one row per visit (a run of activity with no gap longer than
  # `Relay.Usage.idle_gap/0`). Written only by `Relay.Usage.Tracker`, which upserts on the unique
  # `(user_id, started_at)` key, so it never has to track row ids. Deleting the user deletes their
  # visits; deleting the board keeps the visit and forgets where it happened.
  def change do
    create table(:usage_visits) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime, null: false
      add :last_at, :utc_datetime, null: false
      add :seconds, :integer, null: false, default: 0
      add :board_id, references(:boards, on_delete: :nilify_all)
      add :card_refs, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:usage_visits, [:user_id, :started_at])
    create index(:usage_visits, [:started_at])
  end
end
