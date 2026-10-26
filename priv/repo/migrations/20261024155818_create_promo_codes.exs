defmodule Hamaca.Repo.Migrations.CreatePromoCodes do
  use Ecto.Migration

  # RE462 — promo codes (X paid months at Y% off, ADR 0012). A code is stored upper-case and
  # unique; an account redeems at most one, ever (`billing_accounts.promo_code_id`), and how many
  # accounts hold a code is counted from that column — never denormalised. Each payment attempt
  # records the code text and percent it applied, so history stays accurate after a code changes;
  # a 100% code records a $0 attempt, so the amount check relaxes from `> 0` to `>= 0`.
  def up do
    create table(:promo_codes) do
      add :code, :string, null: false
      add :percent_off, :integer, null: false
      add :months, :integer, null: false
      add :max_redemptions, :integer
      add :expires_on, :date
      add :disabled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:promo_codes, [:code])
    create constraint(:promo_codes, :promo_codes_code_upper, check: "code = upper(code)")

    create constraint(:promo_codes, :promo_codes_percent_off_range,
             check: "percent_off BETWEEN 1 AND 100"
           )

    create constraint(:promo_codes, :promo_codes_months_positive, check: "months >= 1")

    create constraint(:promo_codes, :promo_codes_max_redemptions_positive,
             check: "max_redemptions IS NULL OR max_redemptions >= 1"
           )

    alter table(:billing_accounts) do
      add :promo_code_id, references(:promo_codes, on_delete: :restrict)
      add :promo_months_left, :integer, null: false, default: 0
    end

    create index(:billing_accounts, [:promo_code_id])

    create constraint(:billing_accounts, :billing_accounts_promo_months_left_non_negative,
             check: "promo_months_left >= 0"
           )

    alter table(:billing_payment_attempts) do
      add :promo_code, :string
      add :promo_percent_off, :integer
    end

    drop constraint(:billing_payment_attempts, :billing_payment_attempts_amount_positive)

    create constraint(:billing_payment_attempts, :billing_payment_attempts_amount_non_negative,
             check: "amount_cents >= 0"
           )
  end

  def down do
    drop constraint(:billing_payment_attempts, :billing_payment_attempts_amount_non_negative)

    create constraint(:billing_payment_attempts, :billing_payment_attempts_amount_positive,
             check: "amount_cents > 0"
           )

    alter table(:billing_payment_attempts) do
      remove :promo_code
      remove :promo_percent_off
    end

    drop constraint(:billing_accounts, :billing_accounts_promo_months_left_non_negative)
    drop index(:billing_accounts, [:promo_code_id])

    alter table(:billing_accounts) do
      remove :promo_code_id
      remove :promo_months_left
    end

    drop table(:promo_codes)
  end
end
