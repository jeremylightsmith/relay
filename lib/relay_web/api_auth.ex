defmodule RelayWeb.ApiAuth do
  @moduledoc """
  Authenticates JSON API requests by `Authorization: Bearer <board key>`.
  On success assigns `:current_board` and the `:agent` actor; otherwise
  responds 401 JSON and halts. See MMF 09.
  """

  import Plug.Conn

  alias Relay.ApiKeys

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, board} <- ApiKeys.authenticate(token) do
      conn
      |> assign(:current_board, board)
      |> assign(:actor, :agent)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    body = Jason.encode!(%{error: %{code: "unauthorized", message: "Invalid or missing API key"}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
