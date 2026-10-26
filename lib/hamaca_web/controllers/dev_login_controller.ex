defmodule HamacaWeb.DevLoginController do
  @moduledoc """
  Dev/test-only login bypass (`GET /dev/login`): signs in a fixed local
  user without a Google round-trip. The route is compiled only when
  `:dev_routes` is set (dev + test) — never in prod.

  With billing on, a `:signup_promo_code` stashed by a `/?code=` visit is redeemed for the
  dev user (refusals ignored), so a smoke can exercise the sign-up link without Google.
  """

  use HamacaWeb, :controller

  alias Hamaca.Accounts
  alias Hamaca.Billing
  alias HamacaWeb.Auth

  def create(conn, params) do
    user = Accounts.ensure_dev_user!()
    return_to = Auth.local_return_path(params["return_to"])
    code = get_session(conn, :signup_promo_code)

    if code && Billing.enabled?(), do: _redeemed = Billing.redeem_code(user, code, Date.utc_today())

    conn
    |> put_flash(:info, "Signed in as #{user.email}")
    |> Auth.log_in_user(user, return_to)
  end
end
