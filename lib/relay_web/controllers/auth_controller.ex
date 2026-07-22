defmodule RelayWeb.AuthController do
  @moduledoc """
  Google OAuth via Ueberauth: `request` redirects to Google (handled by
  the Ueberauth plug), `callback` upserts the user and starts the
  session, `delete` logs out.

  `return_to` (RLY-69): a caller (e.g. the public board's sign-in link) may add
  `?return_to=<path>` to the request-phase URL. `put_return_to/2` runs before the
  Ueberauth plug on every action, so it captures the param on the request phase and
  stashes it in the session — the callback phase's own request carries no such param,
  so that pass through is a no-op. Only a same-app relative path is accepted (starts
  with `/`, not `//`, no scheme/host) to rule out an open redirect; anything else is
  dropped and `callback` falls back to `~p"/board"`.
  """

  use RelayWeb, :controller

  alias Relay.Accounts
  alias RelayWeb.Auth

  plug :put_return_to
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
    return_to = get_session(conn, :user_return_to)

    case Accounts.upsert_user_from_google(auth) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Signed in as #{user.email}")
        |> Auth.log_in_user(user, return_to)

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

  # Stashes a validated `return_to` param in the session before Ueberauth takes over.
  # Absent or rejected params leave the session untouched (no stale value to clean up —
  # `Auth.put_user_session/2` renews the session on every sign-in anyway).
  defp put_return_to(conn, _opts) do
    case Auth.local_return_path(conn.params["return_to"]) do
      nil -> conn
      path -> put_session(conn, :user_return_to, path)
    end
  end
end
