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
end
