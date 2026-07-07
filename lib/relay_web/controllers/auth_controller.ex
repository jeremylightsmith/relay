defmodule RelayWeb.AuthController do
  @moduledoc """
  Google OAuth via Ueberauth: `request` redirects to Google (handled by
  the Ueberauth plug), `callback` upserts the user and starts the
  session, `delete` logs out.
  """

  use RelayWeb, :controller

  alias Relay.Accounts
  alias RelayWeb.Auth

  plug Ueberauth

  @doc """
  Request phase. The Ueberauth plug redirects to Google before this
  action runs; reaching it means the provider was not recognized.
  """
  def request(conn, _params) do
    conn
    |> put_flash(:error, "Authentication provider not supported.")
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case Accounts.upsert_user_from_google(auth) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Signed in as #{user.email}")
        |> Auth.log_in_user(user)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Google sign-in failed. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> put_flash(:error, "Google sign-in failed. Please try again.")
    |> redirect(to: ~p"/")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> Auth.log_out_user()
  end
end
