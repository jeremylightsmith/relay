defmodule RelayWeb.ApiUserAuthTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Accounts

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "a valid user token reaches the feed", %{conn: conn} do
    {:ok, %{token: token}} = Accounts.create_user_api_token(insert(:user))

    conn = conn |> auth(token) |> get(~p"/api/all/feed")
    assert json_response(conn, 200)["meta"]["count"] == 0
  end

  test "a missing token returns 401", %{conn: conn} do
    assert conn |> get(~p"/api/all/feed") |> json_response(401) |> get_in(["error", "code"]) ==
             "unauthorized"
  end

  test "malformed, unknown, and revoked tokens return 401", %{conn: conn} do
    {:ok, %{user_api_token: record, token: token}} = Accounts.create_user_api_token(insert(:user))

    assert conn |> auth("garbage") |> get(~p"/api/all/feed") |> json_response(401)
    assert conn |> auth("relayu_deadbeef_nope") |> get(~p"/api/all/feed") |> json_response(401)

    {:ok, _} = Accounts.revoke_user_api_token(record)
    assert conn |> auth(token) |> get(~p"/api/all/feed") |> json_response(401)
  end

  test "a board API key cannot authenticate the user-scoped scope", %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: board_token}} = Relay.ApiKeys.create_key(board, board.owner)

    assert conn |> auth(board_token) |> get(~p"/api/all/feed") |> json_response(401)
  end
end
