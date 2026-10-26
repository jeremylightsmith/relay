defmodule HamacaWeb.CanonicalHostRoutingTest do
  @moduledoc """
  RE480: through the real endpoint and router, only `:browser` pages on an extra host 301 to
  the canonical origin; the API, install scripts and webhooks answer in place on every host.
  """
  use HamacaWeb.ConnCase, async: true

  # The request runs in the test process, so the plug's `Hamaca.Config` read finds this
  # per-process list (ADR 0009) — no global app-env write.
  setup %{conn: conn} do
    Process.put(:extra_hosts, ["relayboard.fly.dev", "www.hamaca.app"])
    {:ok, old_host: %{conn | host: "relayboard.fly.dev"}}
  end

  test "a browser page on an extra host 301s to the canonical origin", %{old_host: conn} do
    conn = get(conn, "/board")

    assert conn.status == 301
    assert get_resp_header(conn, "location") == [HamacaWeb.Endpoint.url() <> "/board"]
  end

  test "the shipped app's embedded page loads signed in on an extra host", %{old_host: conn} do
    conn = conn |> log_in_user() |> get("/boards?embed=1")

    assert html_response(conn, 200)
  end

  test "a later embedded page with no ?embed=1 still loads on an extra host", %{old_host: conn} do
    user = insert(:user)

    conn =
      conn
      |> Plug.Test.init_test_session(user_id: user.id, embed: true)
      |> get("/boards")

    assert html_response(conn, 200)
  end

  test "the board-key API answers in place on an extra host", %{old_host: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Hamaca.ApiKeys.create_key(board, board.owner)

    conn = conn |> put_req_header("authorization", "Bearer " <> token) |> get("/api/board")

    assert json_response(conn, 200)["board"]["key"] == board.key
  end

  test "/api/version answers in place on an extra host", %{old_host: conn} do
    conn = get(conn, "/api/version")

    assert conn.status == 200
  end

  test "the install script answers in place on an extra host", %{old_host: conn} do
    conn = get(conn, "/b/streaks/install")

    assert response(conn, 200) =~ HamacaWeb.Endpoint.url()
  end

  test "the Stripe webhook answers in place on an extra host", %{old_host: conn} do
    conn = post(conn, "/webhooks/stripe", %{})

    refute conn.status == 301
    assert conn.status == 404
  end

  test "a browser page on the default host is not redirected", %{conn: conn} do
    conn = get(conn, "/board")

    refute conn.status == 301
    assert conn.status == 302
  end
end
