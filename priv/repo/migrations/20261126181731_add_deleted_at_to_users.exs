defmodule Hamaca.Repo.Migrations.AddDeletedAtToUsers do
  use Ecto.Migration

  # RE509: account deletion tombstones the users row (comments, activities and votes cascade on a
  # hard delete). A non-nil deleted_at is a deleted account; every lookup skips it. The tombstone
  # clears provider_uid so the person can sign up afresh, so the column becomes nullable — but
  # only for a tombstone: a live account still always has one.
  def change do
    alter table(:users) do
      add :deleted_at, :utc_datetime
      modify :provider_uid, :string, null: true, from: {:string, null: false}
    end

    create constraint(:users, :users_live_provider_uid_present,
             check: "provider_uid IS NOT NULL OR deleted_at IS NOT NULL"
           )
  end
end
