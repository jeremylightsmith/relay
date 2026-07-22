defmodule Relay.Repo.Migrations.AddPostedByUserIdToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :posted_by_user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:cards, [:posted_by_user_id])
  end
end
