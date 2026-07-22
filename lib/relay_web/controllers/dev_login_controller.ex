defmodule RelayWeb.DevLoginController do
  @moduledoc """
  Dev/test-only login bypass (`GET /dev/login`): signs in a fixed local
  user without a Google round-trip. The route is compiled only when
  `:dev_routes` is set (dev + test) — never in prod.
  """

  use RelayWeb, :controller

  alias Relay.Accounts
  alias RelayWeb.Auth

  def create(conn, params) do
    user = Accounts.ensure_dev_user!()
    return_to = Auth.local_return_path(params["return_to"])

    conn
    |> put_flash(:info, "Signed in as #{user.email}")
    |> Auth.log_in_user(user, return_to)
  end
end
