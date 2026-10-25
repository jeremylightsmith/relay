defmodule Schemas.BillingPaymentAttempt do
  @moduledoc """
  One charge to a billing account's card (RE460, ADR 0012), committed before Stripe is called.

  At most one attempt per account is open (`open_statuses/0`) — enforced by the partial unique
  index `billing_payment_attempts_one_open_per_account` — so an answer we did not get blocks
  further charges until it is resolved. `idempotency_key` is unique and is the key the charge is
  sent to Stripe with. `paid_through_before` is the account's `paid_through` when the attempt
  opened. `promo_code` / `promo_percent_off` are the code text and percent the attempt applied
  (RE462), nil when it carried none — a 100% code records a $0 attempt.

  `billing_account_id` is set programmatically on the struct, never cast from input.
  """

  use Ecto.Schema

  @statuses [:pending, :succeeded, :failed, :unknown, :not_charged]
  @open_statuses [:pending, :unknown]
  # `:trial_end` is produced by nothing since Free replaced the trial (RE469); historical attempts
  # still load through it.
  @kinds [:trial_end, :renewal, :returned]
  @sources [:clock, :card_saved, :admin, :upgrade]

  schema "billing_payment_attempts" do
    field :status, Ecto.Enum, values: @statuses
    field :kind, Ecto.Enum, values: @kinds
    field :source, Ecto.Enum, values: @sources
    field :amount_cents, :integer
    field :period_start, :date
    field :period_end, :date
    field :billing_day, :integer
    field :attempt_number, :integer
    field :idempotency_key, :string
    field :paid_through_before, :date
    field :stripe_customer_id, :string
    field :stripe_payment_method_id, :string
    field :stripe_payment_intent_id, :string
    field :receipt_url, :string
    field :decline_reason, :string
    field :error, :string
    field :resolved_at, :utc_datetime
    field :promo_code, :string
    field :promo_percent_off, :integer

    belongs_to :billing_account, Schemas.BillingAccount

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Every attempt status."
  @spec statuses() :: [:pending | :succeeded | :failed | :unknown | :not_charged]
  def statuses, do: @statuses

  @doc "The statuses of an attempt still awaiting an answer — at most one per account."
  @spec open_statuses() :: [:pending | :unknown]
  def open_statuses, do: @open_statuses

  @doc """
  What an attempt charges for: `:trial_end` the first charge after a trial (historical only —
  nothing opens one since RE469); `:renewal` the period starting `paid_through + 1` (billing date
  kept); `:returned` a fresh month starting today (a Free account upgrading).
  """
  @spec kinds() :: [:trial_end | :renewal | :returned]
  def kinds, do: @kinds

  @doc """
  What opened an attempt: the billing clock, a card being saved, the superadmin's "Retry charge
  now" (RE463), or the $0 upgrade (RE469). Only a `:clock` decline sends the card-declined email
  or counts toward the grace day's one retry.
  """
  @spec sources() :: [:clock | :card_saved | :admin | :upgrade]
  def sources, do: @sources
end
