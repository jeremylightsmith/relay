defmodule HamacaWeb.DevLoginControllerTest do
  use HamacaWeb.ConnCase, async: true

  alias Hamaca.Billing
  alias Hamaca.Repo
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

  describe "GET /dev/login with a sign-up code (scenario 15)" do
    setup do
      Process.put(:billing_enabled, true)
      %{relayconf: insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)}
    end

    test "redeems the session's code for the dev user", %{conn: conn, relayconf: relayconf} do
      conn |> Plug.Test.init_test_session(signup_promo_code: "RELAYCONF") |> get(~p"/dev/login")

      assert Billing.get_account(Repo.get_by!(User, provider: "dev")).promo_code_id == relayconf.id
    end

    test "with no session code the dev user holds none", %{conn: conn} do
      get(conn, ~p"/dev/login")

      account = Billing.get_account(Repo.get_by!(User, provider: "dev"))
      assert is_nil(account) or is_nil(account.promo_code_id)
    end
  end
end
