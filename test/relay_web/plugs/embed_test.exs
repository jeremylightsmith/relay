defmodule RelayWeb.Plugs.EmbedTest do
  use RelayWeb.ConnCase, async: true

  alias RelayWeb.Plugs.Embed

  # A conn for `path` with a test session initialized, so the plug can read and
  # write the session exactly as it does behind the :browser pipeline.
  defp session_conn(path) do
    :get
    |> Phoenix.ConnTest.build_conn(path)
    |> Plug.Test.init_test_session(%{})
  end

  test "?embed=1 promotes into the session and assigns true" do
    conn = Embed.call(session_conn("/board/x?embed=1"), [])

    assert get_session(conn, :embed) == true
    assert conn.assigns.embed == true
  end

  test "?embed=0 clears a previously-embedded session" do
    conn =
      "/board/x?embed=0"
      |> session_conn()
      |> put_session(:embed, true)
      |> Embed.call([])

    assert get_session(conn, :embed) == false
    assert conn.assigns.embed == false
  end

  test "a truthy relay_embed cookie promotes into the session and assigns true" do
    conn =
      "/board/x"
      |> session_conn()
      |> Plug.Test.put_req_cookie("relay_embed", "1")
      |> Embed.call([])

    assert get_session(conn, :embed) == true
    assert conn.assigns.embed == true
  end

  test "an already-promoted session survives a request with no param and no cookie" do
    conn =
      "/board/x"
      |> session_conn()
      |> put_session(:embed, true)
      |> Embed.call([])

    assert get_session(conn, :embed) == true
    assert conn.assigns.embed == true
  end

  test "the query param wins over the cookie (?embed=0 + relay_embed=1 -> false)" do
    conn =
      "/board/x?embed=0"
      |> session_conn()
      |> Plug.Test.put_req_cookie("relay_embed", "1")
      |> Embed.call([])

    assert get_session(conn, :embed) == false
    assert conn.assigns.embed == false
  end

  test "neither param nor cookie present -> not embedded" do
    conn = Embed.call(session_conn("/board/x"), [])

    assert get_session(conn, :embed) == nil
    assert conn.assigns.embed == false
  end
end
