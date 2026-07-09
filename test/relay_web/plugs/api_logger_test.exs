defmodule RelayWeb.Plugs.ApiLoggerTest do
  # async: false — exercises the app-wide RelayWeb.ApiLog singleton.
  use RelayWeb.ConnCase, async: false

  alias Relay.ApiKeys
  alias RelayWeb.ApiLog

  setup do
    ApiLog.clear()
    _ = :sys.get_state(ApiLog)
    :ok
  end

  defp authed_board do
    user = insert(:user)
    board = insert(:board, owner: user)
    {:ok, %{token: token}} = ApiKeys.create_key(board, user)
    %{board: board, token: token}
  end

  test "records a successful (200) API request with status, method and duration", %{conn: conn} do
    %{board: board, token: token} = authed_board()

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> get(~p"/api/board")
    |> json_response(200)

    _ = :sys.get_state(ApiLog)
    entry = Enum.find(ApiLog.list(), &(&1.path == "/api/board"))

    assert entry
    assert entry.status == 200
    assert entry.method == "GET"
    assert is_integer(entry.duration_ms)
    assert entry.board == %{name: board.name, key: board.key, owner_id: board.owner_id}
  end

  test "records a rejected (401) API request with no board", %{conn: conn} do
    conn |> get(~p"/api/board") |> json_response(401)

    _ = :sys.get_state(ApiLog)
    entry = Enum.find(ApiLog.list(), &(&1.path == "/api/board"))

    assert entry
    assert entry.status == 401
    assert entry.board == nil
  end

  test "never records the Authorization token", %{conn: conn} do
    %{token: token} = authed_board()

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> get(~p"/api/board")
    |> json_response(200)

    _ = :sys.get_state(ApiLog)
    refute inspect(ApiLog.list()) =~ token
  end
end
