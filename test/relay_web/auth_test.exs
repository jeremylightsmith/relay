defmodule RelayWeb.AuthTest do
  use RelayWeb.ConnCase, async: true

  alias Phoenix.LiveView.Socket
  alias Relay.Repo
  alias RelayWeb.Auth
  alias Schemas.Membership
  alias Schemas.Scope

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, RelayWeb.Endpoint.config(:secret_key_base))
      |> Plug.Test.init_test_session(%{})

    %{conn: conn}
  end

  describe "fetch_current_scope/2" do
    test "assigns the current scope when the session has a user id", %{conn: conn} do
      user = insert(:user)
      conn = conn |> put_session(:user_id, user.id) |> Auth.fetch_current_scope([])

      assert conn.assigns.current_scope.user.id == user.id
    end

    test "assigns nil without a session user id", %{conn: conn} do
      conn = Auth.fetch_current_scope(conn, [])
      assert conn.assigns.current_scope == nil
    end

    test "assigns nil when the user no longer exists", %{conn: conn} do
      conn = conn |> put_session(:user_id, -1) |> Auth.fetch_current_scope([])
      assert conn.assigns.current_scope == nil
    end
  end

  describe "session_expired?/1 and session_stale?/1" do
    test "a missing stamp is stale but never expired (pre-RLY-127 sessions)" do
      # Grandfathering: expiring these would sign out every existing user on deploy.
      assert Auth.session_stale?(%{"user_id" => 1})
      refute Auth.session_expired?(%{"user_id" => 1})
    end

    test "a fresh stamp is neither stale nor expired" do
      session = %{"session_refreshed_at" => System.system_time(:second)}

      refute Auth.session_stale?(session)
      refute Auth.session_expired?(session)
    end

    test "a stamp older than a day is stale but not expired" do
      session = %{"session_refreshed_at" => System.system_time(:second) - (60 * 60 * 24 + 60)}

      assert Auth.session_stale?(session)
      refute Auth.session_expired?(session)
    end

    test "a stamp older than the 7-day window is expired" do
      session = %{"session_refreshed_at" => System.system_time(:second) - (60 * 60 * 24 * 7 + 60)}

      assert Auth.session_expired?(session)
    end
  end

  describe "fetch_current_scope/2 session window" do
    setup do
      %{user: insert(:user)}
    end

    test "a session stamped inside the throttle is not re-stamped", %{conn: conn, user: user} do
      stamp = System.system_time(:second) - 60

      conn =
        conn
        |> put_session(:user_id, user.id)
        |> put_session(:session_refreshed_at, stamp)
        |> Auth.fetch_current_scope([])

      assert conn.assigns.current_scope.user.id == user.id
      # Unchanged stamp == no session write == no Set-Cookie on this response.
      assert get_session(conn, :session_refreshed_at) == stamp
    end

    test "a session stamped over a day ago is re-stamped", %{conn: conn, user: user} do
      stale = System.system_time(:second) - (60 * 60 * 24 + 60)

      conn =
        conn
        |> put_session(:user_id, user.id)
        |> put_session(:session_refreshed_at, stale)
        |> Auth.fetch_current_scope([])

      assert conn.assigns.current_scope.user.id == user.id
      assert get_session(conn, :session_refreshed_at) > stale
    end

    test "a session with no stamp is grandfathered in and stamped", %{conn: conn, user: user} do
      conn = conn |> put_session(:user_id, user.id) |> Auth.fetch_current_scope([])

      assert conn.assigns.current_scope.user.id == user.id
      assert is_integer(get_session(conn, :session_refreshed_at))
    end

    test "a session stamped past the window is rejected and cleared", %{conn: conn, user: user} do
      expired = System.system_time(:second) - (60 * 60 * 24 * 7 + 60)

      conn =
        conn
        |> put_session(:user_id, user.id)
        |> put_session(:session_refreshed_at, expired)
        |> Auth.fetch_current_scope([])

      assert conn.assigns.current_scope == nil
      refute get_session(conn, :user_id)
    end

    test "an anonymous session is left untouched", %{conn: conn} do
      conn = Auth.fetch_current_scope(conn, [])

      assert conn.assigns.current_scope == nil
      # Stamping anonymous visitors would put a Set-Cookie on every marketing page.
      refute get_session(conn, :session_refreshed_at)
    end
  end

  describe "require_authenticated/2" do
    test "halts and redirects to the sign-in page without a current scope", %{conn: conn} do
      conn =
        conn
        |> Phoenix.Controller.fetch_flash()
        |> assign(:current_scope, nil)
        |> Auth.require_authenticated([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/"
    end

    test "passes through with a current scope", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> Auth.require_authenticated([])

      refute conn.halted
    end
  end

  describe "put_user_session/2" do
    test "renews the session and stores the user id without redirecting", %{conn: conn} do
      user = insert(:user)

      conn = Auth.put_user_session(conn, user)

      assert get_session(conn, :user_id) == user.id
      refute conn.halted
      assert conn.status == nil
    end

    test "stamps the session refresh time at sign-in", %{conn: conn} do
      user = insert(:user)

      conn = Auth.put_user_session(conn, user)

      assert_in_delta get_session(conn, :session_refreshed_at), System.system_time(:second), 5
    end

    test "resolves pending invites for the user's email", %{conn: conn} do
      user = insert(:user, email: "invitee@example.com")
      membership = insert(:membership, email: "invitee@example.com", user: nil)

      Auth.put_user_session(conn, user)

      assert Repo.get!(Membership, membership.id).user_id == user.id
    end
  end

  describe "log_in_user/2" do
    test "renews the session, stores the user id, and redirects to the board", %{conn: conn} do
      user = insert(:user)
      conn = conn |> put_session(:stale, "value") |> Auth.log_in_user(user)

      assert get_session(conn, :user_id) == user.id
      refute get_session(conn, :stale)
      assert redirected_to(conn) == ~p"/board"
    end

    test "resolves pending invites for the logging-in user", %{conn: conn} do
      board = Relay.Factory.insert(:board)
      {:ok, invited} = Relay.Members.invite(board, "join@example.com")
      assert invited.user_id == nil

      user = Relay.Factory.insert(:user, email: "join@example.com")
      Auth.log_in_user(conn, user)

      assert Relay.Members.member?(board, user)
    end
  end

  describe "log_out_user/1" do
    test "clears the session and redirects to the sign-in page", %{conn: conn} do
      user = insert(:user)
      conn = conn |> put_session(:user_id, user.id) |> Auth.log_out_user()

      refute get_session(conn, :user_id)
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "on_mount :mount_current_scope session window" do
    test "assigns the scope for a session inside the window" do
      user = insert(:user)
      session = %{"user_id" => user.id, "session_refreshed_at" => System.system_time(:second)}

      {:cont, socket} = Auth.on_mount(:mount_current_scope, %{}, session, %Socket{})

      assert socket.assigns.current_scope.user.id == user.id
    end

    test "still mounts a session with no stamp (grandfathered, expiry-only path)" do
      user = insert(:user)

      {:cont, socket} = Auth.on_mount(:mount_current_scope, %{}, %{"user_id" => user.id}, %Socket{})

      # A mount has no conn and cannot re-stamp, so a missing stamp must still mount.
      assert socket.assigns.current_scope.user.id == user.id
    end

    test "refuses a session stamped past the window" do
      user = insert(:user)

      session = %{
        "user_id" => user.id,
        "session_refreshed_at" => System.system_time(:second) - (60 * 60 * 24 * 7 + 60)
      }

      # Closes the hole where a stale cookie mounts a LiveView on socket reconnect
      # without ever passing through the plug pipeline.
      {:cont, socket} = Auth.on_mount(:mount_current_scope, %{}, session, %Socket{})

      assert socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :mount_embed" do
    test "assigns @embed true when the session flags embedded" do
      {:cont, socket} =
        Auth.on_mount(:mount_embed, %{}, %{"embed" => true}, %Socket{})

      assert socket.assigns.embed == true
    end

    test "assigns @embed false when the session has no embed flag" do
      {:cont, socket} = Auth.on_mount(:mount_embed, %{}, %{}, %Socket{})

      assert socket.assigns.embed == false
    end
  end
end
