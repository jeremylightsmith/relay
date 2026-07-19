defmodule RelayWeb.EndpointSessionTest do
  use RelayWeb.ConnCase, async: true

  alias RelayWeb.SessionPolicy

  test "the sign-in response writes _relay_key as a persistent 7-day cookie", %{conn: conn} do
    conn = get(conn, ~p"/dev/login")

    cookie = conn.resp_cookies["_relay_key"]

    # Without max_age this is a pure browser-session cookie, which mobile Safari
    # drops on tab eviction — the whole bug (RLY-127).
    assert cookie.max_age == SessionPolicy.max_age()
    assert cookie.max_age == 604_800
  end

  test "an already-fresh session gets no new Set-Cookie (the daily throttle)", %{conn: conn} do
    # Request 1 signs in; request 2 consumes the sign-in flash, which is itself a
    # session write. Request 3 is the one that must be silent.
    conn =
      conn
      |> get(~p"/dev/login")
      |> recycle()
      |> get(~p"/privacy")
      |> recycle()

    conn = get(conn, ~p"/privacy")

    assert conn.status == 200
    refute Map.has_key?(conn.resp_cookies, "_relay_key")
  end

  test "a stale session is re-stamped with a fresh 7-day Set-Cookie", %{conn: conn} do
    user = insert(:user)
    stale = System.system_time(:second) - (60 * 60 * 24 + 60)

    conn =
      conn
      |> Plug.Test.init_test_session(user_id: user.id, session_refreshed_at: stale)
      |> get(~p"/privacy")

    cookie = conn.resp_cookies["_relay_key"]

    # This is the whole feature end-to-end: enforce_session_window/1 re-stamping
    # the session is only useful because Plug.Session turns that write into a
    # Set-Cookie carrying a fresh Max-Age — proven here through the real endpoint
    # rather than assumed from the unit-level stamp assertion.
    assert cookie.max_age == SessionPolicy.max_age()
  end
end
