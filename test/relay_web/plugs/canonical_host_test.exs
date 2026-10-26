defmodule RelayWeb.Plugs.CanonicalHostTest do
  use RelayWeb.ConnCase, async: true

  alias RelayWeb.Plugs.CanonicalHost

  # The plug reads `:extra_hosts` through `Relay.Config`, so a per-process value (ADR 0009) is
  # all a test needs — no global app-env write.
  setup do
    Process.put(:extra_hosts, ["relayboard.fly.dev", "www.hamaca.app"])
    :ok
  end

  defp call(method, path, host) do
    method
    |> Phoenix.ConnTest.build_conn(path)
    |> Map.put(:host, host)
    |> CanonicalHost.call(CanonicalHost.init([]))
  end

  defp assert_untouched(conn) do
    refute conn.halted
    assert conn.status == nil
  end

  test "a browser GET on an extra host 301s to the same path and query on the canonical origin" do
    conn = call(:get, "/board/relay?card=RE1", "relayboard.fly.dev")

    assert conn.status == 301
    assert conn.halted
    assert get_resp_header(conn, "location") == [RelayWeb.Endpoint.url() <> "/board/relay?card=RE1"]
  end

  test "a GET with no query string redirects without a trailing ?" do
    conn = call(:get, "/docs", "www.hamaca.app")

    assert conn.status == 301
    assert get_resp_header(conn, "location") == [RelayWeb.Endpoint.url() <> "/docs"]
  end

  test "the host match is case-insensitive" do
    assert call(:get, "/board", "RelayBoard.Fly.Dev").status == 301
  end

  test "the canonical host is left alone" do
    assert_untouched(call(:get, "/board", URI.parse(RelayWeb.Endpoint.url()).host))
  end

  test "a host outside the list is left alone" do
    assert_untouched(call(:get, "/board", "some-other.example"))
  end

  test "non-GET requests on an extra host answer in place" do
    for {method, path} <- [post: "/board", put: "/board", patch: "/board", delete: "/logout"] do
      assert_untouched(call(method, path, "relayboard.fly.dev"))
    end
  end

  test "OAuth paths answer in place on an extra host" do
    assert_untouched(call(:get, "/auth/google/callback?code=x", "relayboard.fly.dev"))
    assert_untouched(call(:get, "/auth/google", "relayboard.fly.dev"))
  end

  test "attachment paths answer in place on an extra host" do
    assert_untouched(call(:get, "/attachments/abc", "relayboard.fly.dev"))
    assert_untouched(call(:get, "/attachments/abc/view", "relayboard.fly.dev"))
  end

  test "pass-through matches the first path segment, not a string prefix" do
    assert call(:get, "/authors", "relayboard.fly.dev").status == 301
  end

  test "with no extra hosts configured the plug is a no-op" do
    Process.put(:extra_hosts, [])

    assert_untouched(call(:get, "/board", "relayboard.fly.dev"))
  end

  test "with nothing overridden the plug falls through to the app env default" do
    Process.delete(:extra_hosts)

    assert_untouched(call(:get, "/board", "relayboard.fly.dev"))
  end
end
