defmodule HamacaWeb.AuthTest do
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Repo
  alias HamacaWeb.Auth
  alias Phoenix.LiveView.Socket
  alias Schemas.Membership
  alias Schemas.Scope

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, HamacaWeb.Endpoint.config(:secret_key_base))
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
      board = Hamaca.Factory.insert(:board)
      {:ok, invited} = Hamaca.Members.invite(board, "join@example.com")
      assert invited.user_id == nil

      user = Hamaca.Factory.insert(:user, email: "join@example.com")
      Auth.log_in_user(conn, user)

      assert Hamaca.Members.member_user_id?(board.id, user.id)
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

  describe "suspension lockout (RE510)" do
    defp suspended_user, do: insert(:user, suspended_at: DateTime.truncate(DateTime.utc_now(), :second))

    test "fetch_current_scope/2 treats a suspended user as signed out and renews the session", %{conn: conn} do
      user = suspended_user()

      conn = conn |> put_session(:user_id, user.id) |> Auth.fetch_current_scope([])

      assert conn.assigns.current_scope == nil
      assert get_session(conn, :user_id) == nil
    end

    test "a suspended user's request to a signed-in page redirects to sign-in" do
      conn = build_conn() |> log_in_user(suspended_user()) |> get(~p"/boards")

      assert redirected_to(conn) == ~p"/"
    end

    test "a :require_authenticated LiveView refuses to mount for a suspended user" do
      conn = Plug.Test.init_test_session(build_conn(), %{"user_id" => suspended_user().id})

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/boards")
    end

    # The HTTP render above is refused by the plug before mount ever runs; a socket
    # (re)connect skips the plug, so the on_mount check is exercised directly here.
    test "on_mount :require_authenticated halts a socket mount for a suspended user" do
      socket = %Socket{endpoint: HamacaWeb.Endpoint, assigns: %{__changed__: %{}, flash: %{}}}

      assert {:halt, socket} =
               Auth.on_mount(:require_authenticated, %{}, %{"user_id" => suspended_user().id}, socket)

      assert socket.assigns.current_scope == nil
      assert socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "put_user_session/2 stores the user's live_socket_id", %{conn: conn} do
      user = insert(:user)

      conn = Auth.put_user_session(conn, user)

      assert get_session(conn, :live_socket_id) == "users_sessions:#{user.id}"
      assert get_session(conn, :live_socket_id) == Auth.live_socket_id(user)
    end

    test "disconnect_user/1 broadcasts disconnect on the user's live socket topic" do
      user = insert(:user)
      HamacaWeb.Endpoint.subscribe("users_sessions:#{user.id}")

      assert Auth.disconnect_user(user) == :ok

      assert_receive %Phoenix.Socket.Broadcast{topic: "users_sessions:" <> _, event: "disconnect"}
    end

    test "a suspended user's bearer token is refused by /api/all" do
      user = insert(:user)
      {:ok, %{token: token}} = Hamaca.Accounts.create_user_api_token(user)
      user |> Ecto.Changeset.change(suspended_at: DateTime.truncate(DateTime.utc_now(), :second)) |> Repo.update!()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/all/boards")

      assert conn.status == 401
    end

    test "a suspended owner's board API key keeps working" do
      owner = suspended_user()
      board = insert(:board, owner: owner)
      {:ok, %{token: token}} = Hamaca.ApiKeys.create_key(board, owner)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get(~p"/api/cards")

      assert json_response(conn, 200)
    end

    test "a suspended owner's board still renders for its members" do
      owner = insert(:user)
      board = Hamaca.Boards.get_or_create_default_board(owner)
      owner |> Ecto.Changeset.change(suspended_at: DateTime.truncate(DateTime.utc_now(), :second)) |> Repo.update!()
      member = insert(:user)
      insert(:membership, board: board, user: member, email: member.email)

      conn = log_in_user(build_conn(), member)

      assert {:ok, _view, _html} = live(conn, ~p"/board/#{board.slug}")
    end
  end
end
