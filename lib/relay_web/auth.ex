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
  alias Relay.Members
  alias RelayWeb.SessionPolicy
  alias Schemas.Scope

  @doc """
  Plug: assigns `:current_scope` from the session (nil when logged out), and
  enforces the 7-day session window on the way through — expiring a session past
  the window and sliding one that is merely stale (RLY-127).
  """
  def fetch_current_scope(conn, _opts) do
    conn = enforce_session_window(conn)
    user_id = get_session(conn, :user_id)
    user = user_id && Accounts.get_user(user_id)
    assign(conn, :current_scope, Scope.for_user(user))
  end

  @doc """
  True when `session` carries a `session_refreshed_at` stamp older than
  `RelayWeb.SessionPolicy.max_age/0`.

  Takes the raw session map (string keys) rather than a `conn`, so the plug and the
  `on_mount` hook — which has no `conn` — share exactly one predicate.

  A **missing** stamp is NOT expired: sessions predating RLY-127 have none, and
  expiring them would sign out every existing user on deploy. That is not a
  security regression — those cookies never expire today.
  """
  def session_expired?(session) when is_map(session) do
    case session["session_refreshed_at"] do
      stamp when is_integer(stamp) -> now() - stamp > SessionPolicy.max_age()
      _other -> false
    end
  end

  @doc """
  True when `session` should be re-stamped: its stamp is older than
  `RelayWeb.SessionPolicy.refresh_after/0`, or it has none at all (a pre-RLY-127
  session being grandfathered in).
  """
  def session_stale?(session) when is_map(session) do
    case session["session_refreshed_at"] do
      stamp when is_integer(stamp) -> now() - stamp >= SessionPolicy.refresh_after()
      _other -> true
    end
  end

  @doc """
  Re-stamps the session's refresh time, sliding the 7-day window forward.

  This is a session write, and `Plug.Session` only emits `Set-Cookie` on a write —
  that write is what refreshes the cookie's `Max-Age`. Public because the native
  shell's session verify (`RelayWeb.NativeAuthController.me/2`) is the native app's
  only touch point.
  """
  def refresh_session(conn), do: put_session(conn, :session_refreshed_at, now())

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

  @doc """
  Establishes a signed-in session for `user`: resolves any pending invites,
  renews the session, and stores `:user_id`. Does **not** redirect — the web
  flow (`log_in_user/2`) adds the redirect; the native JSON flow renders the
  response carrying the `Set-Cookie: _relay_key=…` header instead.
  """
  def put_user_session(conn, user) do
    Members.resolve_invites_for_user(user)

    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> refresh_session()
  end

  @doc """
  Establishes the session (see `put_user_session/2`) and redirects — to `return_to`
  when given a validated local path (RLY-69's OAuth `return_to`, e.g. back to the
  public board a visitor signed in from), otherwise to the board.
  """
  def log_in_user(conn, user, return_to \\ nil) do
    conn
    |> put_user_session(user)
    |> redirect(to: return_to || ~p"/board")
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
    * `:mount_embed` — assigns `embed` (bool) from the session so authenticated
      LiveViews can suppress web chrome when hosted in the native shell.
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

  def on_mount(:mount_embed, _params, session, socket) do
    {:cont, Phoenix.Component.assign_new(socket, :embed, fn -> session["embed"] == true end)}
  end

  # Expiry only, no re-stamp: a LiveView mount has no `conn` and cannot write a
  # cookie. Checking here closes the hole where a stale cookie mounts a LiveView on
  # socket reconnect without ever passing through the plug pipeline.
  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      user =
        if session_expired?(session) do
          nil
        else
          session["user_id"] && Accounts.get_user(session["user_id"])
        end

      Scope.for_user(user)
    end)
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  # Expire or slide the session (RLY-127). Only signed-in sessions are touched:
  # a missing stamp means "re-stamp now", so stamping anonymous visitors would put
  # a Set-Cookie on every response of the marketing pages.
  defp enforce_session_window(conn) do
    session = get_session(conn)

    cond do
      is_nil(session["user_id"]) -> conn
      session_expired?(session) -> renew_session(conn)
      session_stale?(session) -> refresh_session(conn)
      true -> conn
    end
  end

  defp now, do: System.system_time(:second)
end
