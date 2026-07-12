defmodule RelayWeb.AuthTest do
  use RelayWeb.ConnCase, async: true

  alias RelayWeb.Auth
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
end
