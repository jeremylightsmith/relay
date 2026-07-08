defmodule RelayWeb.ApiAuthTest do
  use RelayWeb.ConnCase, async: true

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "valid key authenticates and reaches the board endpoint", %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)

    conn = conn |> auth(token) |> get(~p"/api/board")
    assert json_response(conn, 200)["board"]["key"] == board.key
  end

  test "missing key returns 401", %{conn: conn} do
    conn = get(conn, ~p"/api/board")
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end

  test "malformed / unknown / revoked key returns 401", %{conn: conn} do
    board = insert(:board)
    {:ok, %{api_key: key, token: token}} = Relay.ApiKeys.create_key(board, board.owner)

    assert conn |> auth("garbage") |> get(~p"/api/board") |> json_response(401)
    assert conn |> auth("relay_deadbeef_nope") |> get(~p"/api/board") |> json_response(401)

    {:ok, _} = Relay.ApiKeys.revoke(key)
    assert conn |> auth(token) |> get(~p"/api/board") |> json_response(401)
  end
end
