defmodule RelayWeb.DevLoginControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Repo
  alias Schemas.User

  test "GET /dev/login signs in the dev user and redirects to the board", %{conn: conn} do
    conn = get(conn, ~p"/dev/login")

    user = Repo.get_by!(User, provider: "dev")
    assert user.email == "dev@relay.local"
    assert get_session(conn, :user_id) == user.id
    assert redirected_to(conn) == ~p"/board"
  end

  test "GET /dev/login is idempotent across sign-ins", %{conn: conn} do
    get(conn, ~p"/dev/login")
    get(conn, ~p"/dev/login")

    assert Repo.aggregate(User, :count) == 1
  end

  test "GET /dev/login honors a local return_to", %{conn: conn} do
    conn = get(conn, ~p"/dev/login?return_to=/board/acme/public")
    assert redirected_to(conn) == "/board/acme/public"
  end

  test "GET /dev/login rejects an external return_to and falls back to /board", %{conn: conn} do
    conn = get(conn, "/dev/login?return_to=https://evil.com")
    assert redirected_to(conn) == ~p"/board"
  end

  test "GET /dev/login rejects a protocol-relative return_to", %{conn: conn} do
    conn = get(conn, "/dev/login?return_to=//evil.com")
    assert redirected_to(conn) == ~p"/board"
  end
end
