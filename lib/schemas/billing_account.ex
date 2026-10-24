defmodule Schemas.BillingAccount do
  @moduledoc """
  A user's billing facts (RE460, ADR 0012) — one row per user, the board owner being the payer.

  Standing (`Relay.Billing.Standing`) is derived from these facts and never stored.
  `paid_through` is the only thing that grants paid access; `trial_ends_on` is the trial's last
  day; `billing_day` (1–31) is the day of the month the account renews on. `comped` and
  `held_on` / `hold_reason` are admin facts; `cancelled_on` / `access_until` record a cancelled
  plan. The `card_*` fields describe the saved card (`card_payment_method_id` is Stripe's id).
  `promo_code_id` is the one promo code the account ever redeemed (RE462) and
  `promo_months_left` how many discounted paid months it has left.

  `user_id`, `promo_code_id` and `promo_months_left` are set programmatically on the struct,
  never cast from input. Every write goes through `Relay.Billing`.
  """

  use Ecto.Schema

  schema "billing_accounts" do
    field :trial_ends_on, :date
    field :paid_through, :date
    field :billing_day, :integer
    field :comped, :boolean, default: false
    field :held_on, :date
    field :hold_reason, :string
    field :cancelled_on, :date
    field :access_until, :date
    field :stripe_customer_id, :string
    field :card_payment_method_id, :string
    field :card_brand, :string
    field :card_last4, :string
    field :card_exp_month, :integer
    field :card_exp_year, :integer
    field :promo_months_left, :integer, default: 0

    belongs_to :user, Schemas.User
    belongs_to :promo_code, Schemas.PromoCode
    has_many :payment_attempts, Schemas.BillingPaymentAttempt

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
end
