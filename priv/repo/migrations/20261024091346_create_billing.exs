defmodule Relay.Repo.Migrations.CreateBilling do
  use Ecto.Migration

  # RE460 — billing (ADR 0012). One `billing_accounts` row per user (the board owner pays);
  # `paid_through` is the only thing that grants paid access, and standing is derived from these
  # facts, never stored. A charge is a `billing_payment_attempts` row committed before Stripe is
  # called; at most one attempt per account is open (`pending` or `unknown`), so an answer we did
  # not get blocks further charges until it is resolved.
  def change do
    create table(:billing_accounts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :trial_ends_on, :date
      add :paid_through, :date
      add :billing_day, :integer
      add :comped, :boolean, default: false, null: false
      add :held_on, :date
      add :hold_reason, :string
      add :cancelled_on, :date
      add :access_until, :date
      add :stripe_customer_id, :string
      add :card_payment_method_id, :string
      add :card_brand, :string
      add :card_last4, :string
      add :card_exp_month, :integer
      add :card_exp_year, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:billing_accounts, [:user_id])

    create constraint(:billing_accounts, :billing_accounts_billing_day_range,
             check: "billing_day BETWEEN 1 AND 31"
           )

    create table(:billing_payment_attempts) do
      add :billing_account_id, references(:billing_accounts, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :kind, :string, null: false
      add :source, :string, null: false
      add :amount_cents, :integer, null: false
      add :period_start, :date, null: false
      add :period_end, :date, null: false
      add :billing_day, :integer, null: false
      add :attempt_number, :integer, null: false
      add :idempotency_key, :string, null: false
      add :paid_through_before, :date
      add :stripe_customer_id, :string
      add :stripe_payment_method_id, :string
      add :stripe_payment_intent_id, :string
      add :receipt_url, :string
      add :decline_reason, :string
      add :error, :string
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:billing_payment_attempts, [:billing_account_id])
    create unique_index(:billing_payment_attempts, [:idempotency_key])

    create constraint(:billing_payment_attempts, :billing_payment_attempts_amount_positive,
             check: "amount_cents > 0"
           )

    create unique_index(:billing_payment_attempts, [:billing_account_id],
             where: "status IN ('pending','unknown')",
             name: :billing_payment_attempts_one_open_per_account
           )
  end
end
