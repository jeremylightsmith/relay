defmodule RelayWeb.StripeWebhookController do
  @moduledoc """
  `POST /webhooks/stripe` (RE460): Stripe's webhook. No session and no CSRF — the
  `Stripe-Signature` over the raw body (kept by `RelayWeb.RawBodyReader`) is the authentication,
  checked by `Relay.Billing.verify_webhook/2`. A verified event goes to
  `Relay.Billing.handle_webhook_event/1` and is acknowledged 200 whatever it is; a bad signature
  is 400 `invalid_signature`. 404 while billing is disabled (a self-hosted install has no webhook).
  """

  use RelayWeb, :controller

  alias Relay.Billing
  alias RelayWeb.Api.ErrorJSON

  def create(conn, _params) do
    if Billing.enabled?(), do: handle(conn), else: error(conn, :not_found, "not_found", "Not found")
  end

  defp handle(conn) do
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case Billing.verify_webhook(conn.private[:raw_body], signature) do
      {:ok, event} ->
        :ok = Billing.handle_webhook_event(event)
        json(conn, %{ok: true})

      {:error, :invalid_signature} ->
        error(conn, :bad_request, "invalid_signature", "The Stripe-Signature header does not verify")
    end
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.error(%{code: code, message: message}))
  end
end
