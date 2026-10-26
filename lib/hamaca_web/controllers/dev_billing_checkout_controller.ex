defmodule HamacaWeb.DevBillingCheckoutController do
  @moduledoc """
  Dev/test-only stand-in for Stripe Checkout (RE460), `GET /dev/billing-checkout` — where
  `Hamaca.Billing.Payments.Local` sends a user saving a card. Two links return to the page the
  checkout began on: `succeed` with the Visa 4242 card saved, `decline` with the 0341 card. Both
  must be same-origin paths, so the page can never bounce anyone off-site. Compiled only with
  `:dev_routes` — never in prod.
  """

  use HamacaWeb, :controller

  def show(conn, params) do
    with succeed when is_binary(succeed) <- local_path(params["succeed"]),
         decline when is_binary(decline) <- local_path(params["decline"]) do
      render(conn, :show, succeed: succeed, decline: decline)
    else
      nil -> conn |> put_resp_content_type("text/plain") |> send_resp(400, "succeed and decline must be local paths\n")
    end
  end

  # "/x" only: never "//host" or "/\host" (both read as another origin), nor a full URL.
  defp local_path("/" <> rest = path) when is_binary(rest) do
    if String.starts_with?(rest, ["/", "\\"]), do: nil, else: path
  end

  defp local_path(_other), do: nil
end
