defmodule Relay.Repo.Migrations.CreateBillingAdminEntries do
  use Ecto.Migration

  # RE463 — the superadmin's billing history. One append-only `billing_admin_entries` row per
  # admin action (comp, uncomp, hold, lift hold, extend, retry charge), written by
  # `Relay.Billing.Admin` in the same transaction as the account change. Nothing updates or
  # deletes a row; deleting the account deletes its history, deleting the admin keeps the entry.
  def change do
    create table(:billing_admin_entries) do
      add :billing_account_id, references(:billing_accounts, on_delete: :delete_all), null: false
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :reason, :text
      add :days, :integer
      add :paid_through_before, :date
      add :paid_through_after, :date

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:billing_admin_entries, [:billing_account_id])
  end
end
