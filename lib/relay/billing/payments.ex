defmodule Relay.Billing.Payments do
  @moduledoc """
  The contract a board owner's card and charges go through (RE460, ADR 0012). Stripe stores the
  card and takes off-session charges; a card is saved through Stripe Checkout in setup mode. Our
  own clock decides when to charge — this is never a Stripe Billing subscription.

  `Relay.Billing` resolves the module through `impl/0` (`:billing_payments`, read through
  `Relay.Config`): `Payments.Stripe` (the real `Req` client) by default, `Payments.Local` — the
  credential-free stand-in — in dev and test.
  """

  @typedoc "The card a completed setup saved, and whose it is."
  @type setup :: %{
          user_id: pos_integer(),
          customer_id: String.t(),
          payment_method_id: String.t(),
          brand: String.t(),
          last4: String.t(),
          exp_month: integer(),
          exp_year: integer()
        }

  @typedoc "A succeeded charge."
  @type charged :: %{id: String.t(), receipt_url: String.t() | nil}

  @typedoc "A PaymentIntent as `find_payment/3` reports it; `decline_reason` is nil unless it failed."
  @type found :: %{id: String.t(), status: String.t(), decline_reason: String.t() | nil, receipt_url: String.t() | nil}

  @doc """
  A Checkout session in setup mode for `user`'s card, creating the Stripe customer first when
  `customer_id` is nil. Answers the URL to send the user to and the customer it is for; the user
  comes back to `return_url`.
  """
  @callback create_setup_checkout(
              customer_id :: String.t() | nil,
              user :: Schemas.User.t(),
              return_url :: String.t()
            ) :: {:ok, %{url: String.t(), customer_id: String.t()}} | {:error, term()}

  @doc "The card a completed setup saved — `id` a Checkout Session (`cs_…`) or a SetupIntent (`seti_…`)."
  @callback fetch_setup(id :: String.t()) :: {:ok, setup()} | {:error, term()}

  @doc """
  An off-session charge of `amount_cents` to the saved card under `idempotency_key`. A card the
  bank refuses is `{:error, {:declined, reason}}`; a charge still processing is
  `{:error, {:processing, payment_intent_id}}`; anything else that fails — a timeout, a 5xx — is
  `{:error, term}` and says nothing about whether the card was charged.
  """
  @callback charge(
              customer_id :: String.t(),
              payment_method_id :: String.t(),
              amount_cents :: pos_integer(),
              idempotency_key :: String.t(),
              meta :: %{description: String.t(), receipt_email: String.t() | nil, attempt_id: pos_integer()}
            ) ::
              {:ok, charged()}
              | {:error, {:declined, reason :: String.t()}}
              | {:error, {:processing, payment_intent_id :: String.t()}}
              | {:error, term()}

  @doc """
  The PaymentIntent a payment attempt made: by `payment_intent_id` when known, else the customer's
  intent whose metadata names the attempt, created since it was. `{:ok, :none}` when there is none.
  """
  @callback find_payment(
              customer_id :: String.t(),
              payment_intent_id :: String.t() | nil,
              attempt :: %{id: pos_integer(), inserted_at: DateTime.t()}
            ) :: {:ok, found()} | {:ok, :none} | {:error, term()}

  @doc "The configured implementation: `:billing_payments`, `Payments.Stripe` by default."
  @spec impl() :: module()
  def impl, do: Relay.Config.get(:billing_payments, Relay.Billing.Payments.Stripe)
end
