defmodule Relay.Repo.Migrations.CreateBoardMembers do
  use Ecto.Migration

  def up do
    create table(:board_members) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: true
      add :email, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_members, [:board_id, :email])
    create index(:board_members, [:board_id])
    create index(:board_members, [:user_id])
    create index(:board_members, [:email])

    # Backfill: every existing board's current owner becomes its first member.
    execute("""
    INSERT INTO board_members (board_id, user_id, email, inserted_at, updated_at)
    SELECT b.id, b.owner_id, lower(btrim(u.email)), (now() at time zone 'utc'), (now() at time zone 'utc')
    FROM boards b
    JOIN users u ON u.id = b.owner_id
    """)
  end

  def down do
    drop table(:board_members)
  end
end
