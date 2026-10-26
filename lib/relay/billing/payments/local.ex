defmodule Relay.Billing.Payments.Local do
  @moduledoc """
  Dev and test stand-in for `Relay.Billing.Payments.Stripe` (RE460): the same contract, no
  Stripe account. Selected by `:billing_payments` in `config/dev.exs` and `config/test.exs`.

    * `create_setup_checkout/3` sends the user to the dev checkout page, `/dev/billing-checkout`,
      whose two links return to the page with the 4242 card saved (`succeed`) or the 0341 card
      (`decline`);
    * `fetch_setup/1` reads the card back out of the local setup id,
      `local_<4242|0341|timeout>_<user_id>`;
    * `charge/5` succeeds for `pm_local_4242`, declines `pm_local_0341` for insufficient funds,
      and times out for `pm_local_timeout`;
    * `find_payment/3` finds any attempt charged, as `pi_local_attempt-<id>`.
  """

  @behaviour Relay.Billing.Payments

  alias Relay.Billing.Payments

  @receipts "https://pay.stripe.com/receipts/local/"

  @cards %{
    "4242" => %{payment_method_id: "pm_local_4242", brand: "visa", last4: "4242", exp_month: 8, exp_year: 2028},
    "0341" => %{payment_method_id: "pm_local_0341", brand: "visa", last4: "0341", exp_month: 3, exp_year: 2027},
    "timeout" => %{payment_method_id: "pm_local_timeout", brand: "visa", last4: "0000", exp_month: 1, exp_year: 2030}
  }

  @doc "A test card's fields — as `fetch_setup/1` answers, less the user and customer — for seeding."
  @spec card(:visa_4242 | :visa_0341 | :timeout) :: map()
  def card(:visa_4242), do: @cards["4242"]
  def card(:visa_0341), do: @cards["0341"]
  def card(:timeout), do: @cards["timeout"]

  @impl true
  def create_setup_checkout(_customer_id, user, return_url) do
    # Path-only (the dev checkout only follows same-origin paths), keeping any query it carries.
    path =
      case URI.parse(return_url) do
        %URI{path: path, query: nil} -> path
        %URI{path: path, query: query} -> path <> "?" <> query
      end

    query =
      URI.encode_query(%{
        "succeed" => Payments.with_setup_param(path, "local_4242_#{user.id}"),
        "decline" => Payments.with_setup_param(path, "local_0341_#{user.id}")
      })

    url = return_url |> URI.merge("/dev/billing-checkout?" <> query) |> URI.to_string()
    {:ok, %{url: url, customer_id: "cus_local_#{user.id}"}}
  end

  @impl true
  def fetch_setup("local_" <> rest) do
    with [card, user_id] <- String.split(rest, "_", parts: 2),
         {:ok, card} <- Map.fetch(@cards, card),
         {user_id, ""} <- Integer.parse(user_id) do
      {:ok, Map.merge(card, %{user_id: user_id, customer_id: "cus_local_#{user_id}"})}
    else
      _unknown -> {:error, :not_found}
    end
  end

  def fetch_setup(_id), do: {:error, :not_found}

  @impl true
  def charge(_customer_id, "pm_local_0341", _amount_cents, _idempotency_key, _meta),
    do: {:error, {:declined, "insufficient funds"}}

  def charge(_customer_id, "pm_local_timeout", _amount_cents, _idempotency_key, _meta), do: {:error, :timeout}

  def charge(_customer_id, _payment_method_id, _amount_cents, idempotency_key, _meta),
    do: {:ok, %{id: "pi_local_" <> idempotency_key, receipt_url: @receipts <> idempotency_key}}

  @impl true
  def find_payment(_customer_id, _payment_intent_id, %{id: attempt_id}) do
    {:ok,
     %{
       id: "pi_local_attempt-#{attempt_id}",
       status: "succeeded",
       decline_reason: nil,
       receipt_url: @receipts <> "attempt-#{attempt_id}"
     }}
  end
end
