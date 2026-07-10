defmodule RelayWeb.Auth do
  @moduledoc """
  Session-based authentication plumbing: plugs for the router/controllers
  and `on_mount` hooks for LiveViews. The domain lives in `Relay.Accounts`;
  every Plug/session concern lives here.
  """

  use RelayWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Relay.Accounts
  alias Schemas.Scope

  @doc "Plug: assigns `:current_scope` from the session (nil when logged out)."
  def fetch_current_scope(conn, _opts) do
    user_id = get_session(conn, :user_id)
    user = user_id && Accounts.get_user(user_id)
    assign(conn, :current_scope, Scope.for_user(user))
  end

  @doc "Plug: redirects to the sign-in page when there is no current user."
  def require_authenticated(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
    else
      conn
      |> put_flash(:error, "You must sign in to access this page.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc "Plug: redirects unless the current user is a superadmin (gates /admin)."
  def require_superadmin(conn, _opts) do
    if Scope.superadmin?(conn.assigns[:current_scope]) do
      conn
    else
      conn
      |> put_flash(:error, "You are not authorized to access this page.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc "Renews the session, stores the user id, and redirects to the board."
  def log_in_user(conn, user) do
    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> redirect(to: ~p"/board")
  end

  @doc "Clears the session and redirects to the sign-in page."
  def log_out_user(conn) do
    conn
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  @doc """
  `on_mount` hooks for `live_session`:

    * `:mount_current_scope` — assigns `current_scope` (or nil) and continues.
    * `:require_authenticated` — additionally halts with a redirect to the
      sign-in page when there is no signed-in user.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must sign in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  def on_mount(:require_superadmin, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Scope.superadmin?(socket.assigns.current_scope) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You are not authorized to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      user = session["user_id"] && Accounts.get_user(session["user_id"])
      Scope.for_user(user)
    end)
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
