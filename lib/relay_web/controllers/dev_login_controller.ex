defmodule RelayWeb.DevLoginController do
  @moduledoc """
  Dev/test-only login bypass (`GET /dev/login`): signs in a fixed local
  user without a Google round-trip. The route is compiled only when
  `:dev_routes` is set (dev + test) — never in prod.
  """

  use RelayWeb, :controller

  alias Relay.Accounts
  alias RelayWeb.Auth

  def create(conn, _params) do
    user = Accounts.ensure_dev_user!()

    conn
    |> put_flash(:info, "Signed in as #{user.email}")
    |> Auth.log_in_user(user)
  end
end
