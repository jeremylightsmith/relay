defmodule Relay.Repo.Migrations.CreateBillingNotices do
  use Ecto.Migration

  # RE464 — billing emails (ADR 0012 decision 10). One `billing_notices` row per email sent: the
  # row is inserted (`on_conflict: :nothing`) before the email goes out, and the unique index on
  # (account, kind, period_key) is what guarantees each email is sent at most once per period.
  def change do
    create table(:billing_notices) do
      add :billing_account_id, references(:billing_accounts, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :period_key, :date, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:billing_notices, [:billing_account_id, :kind, :period_key],
             name: :billing_notices_once
           )
  end
end
