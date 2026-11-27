defmodule HamacaWeb.Auth do
  @moduledoc """
  Session-based authentication plumbing: plugs for the router/controllers
  and `on_mount` hooks for LiveViews. The domain lives in `Hamaca.Accounts`;
  every Plug/session concern lives here.
  """

  use HamacaWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Hamaca.Accounts
  alias Hamaca.Members
  alias HamacaWeb.SessionPolicy
  alias Schemas.Scope
  alias Schemas.User

  @suspended_message "This account is suspended. Contact support."

  @doc """
  What a suspended user is told (RE510) — the ONE copy, used by the web OAuth flash and the
  native 403 body.
  """
  @spec suspended_message() :: String.t()
  def suspended_message, do: @suspended_message

  @doc """
  The id every LiveView socket a signed-in tab opens is registered under (written into the
  session by `put_user_session/2`). Phoenix disconnects those sockets on a `"disconnect"`
  broadcast to this topic — see `disconnect_user/1`.
  """
  @spec live_socket_id(User.t()) :: String.t()
  def live_socket_id(%User{id: id}), do: "users_sessions:#{id}"

  @doc """
  Force-disconnects every open LiveView socket of `user` (RE510: called right after a
  suspension). The client reconnects over HTTP, where `fetch_current_scope/2` drops the
  suspended session. Only sessions created after RE510 carry a `live_socket_id`; older ones are
  caught on their next request or mount.
  """
  @spec disconnect_user(User.t()) :: :ok
  def disconnect_user(%User{} = user) do
    HamacaWeb.Endpoint.broadcast(live_socket_id(user), "disconnect", %{})
  end

  @doc """
  Plug: assigns `:current_scope` from the session (nil when logged out), and
  enforces the 7-day session window on the way through — expiring a session past
  the window and sliding one that is merely stale (RLY-127). A suspended user (RE510)
  is treated as signed out and their session is renewed (dropped).
  """
  def fetch_current_scope(conn, _opts) do
    conn = enforce_session_window(conn)
    user_id = get_session(conn, :user_id)
    user = user_id && Accounts.get_user(user_id)

    if User.suspended?(user) do
      conn |> renew_session() |> assign(:current_scope, Scope.for_user(nil))
    else
      assign(conn, :current_scope, Scope.for_user(user))
    end
  end

  @doc """
  True when `session` carries a `session_refreshed_at` stamp older than
  `HamacaWeb.SessionPolicy.max_age/0`.

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
  `HamacaWeb.SessionPolicy.refresh_after/0`, or it has none at all (a pre-RLY-127
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
  shell's session verify (`HamacaWeb.NativeAuthController.me/2`) is the native app's
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
  renews the session, and stores `:user_id` and `:live_socket_id` (so `disconnect_user/1`
  reaches this session's LiveView sockets). Does **not** redirect — the web
  flow (`log_in_user/2`) adds the redirect; the native JSON flow renders the
  response carrying the `Set-Cookie: _hamaca_key=…` header instead.
  """
  def put_user_session(conn, user) do
    Members.resolve_invites_for_user(user)

    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, live_socket_id(user))
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

  @doc """
  Clears the session and redirects — to `return_to` when given a validated local path (RE519's
  consent "Not you?" link, which returns to the authorize page), otherwise to the sign-in page.
  Callers validate `return_to` with `local_return_path/1` first.
  """
  def log_out_user(conn, return_to \\ nil) do
    conn
    |> renew_session()
    |> redirect(to: return_to || ~p"/")
  end

  @doc """
  Validates a post-sign-in `return_to` (RLY-69): returns the path when it is a
  safe in-app relative path, otherwise `nil`. Only a path starting with a single
  `/` is accepted — a scheme/host (`https://evil`) or a protocol-relative
  `//evil/…` are open-redirect vectors and are rejected. One source of truth for
  both OAuth (`AuthController`) and the dev bypass (`DevLoginController`).
  """
  def local_return_path("/" <> _ = path) do
    if String.starts_with?(path, "//"), do: nil, else: path
  end

  def local_return_path(_other), do: nil

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
  # socket reconnect without ever passing through the plug pipeline. A suspended user
  # (RE510) mounts as signed out; the plug drops their cookie on the next HTTP request.
  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      user =
        if session_expired?(session) do
          nil
        else
          session["user_id"] && Accounts.get_user(session["user_id"])
        end

      if User.suspended?(user), do: Scope.for_user(nil), else: Scope.for_user(user)
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
