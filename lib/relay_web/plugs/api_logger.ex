defmodule RelayWeb.Plugs.ApiLogger do
  @moduledoc """
  Captures every inbound `/api` request into `RelayWeb.ApiLog` for the
  `/admin/api` debug view. Sits in the `:api` pipeline **before** `:api_auth`
  so rejected (401) requests are captured too.

  Records a monotonic start, then via `register_before_send/2` computes the
  duration and reads the final status + authenticated board. The Authorization
  header/token is never recorded.
  """
  import Plug.Conn

  alias RelayWeb.ApiLog

  @params_limit 4_000

  def init(opts), do: opts

  def call(conn, _opts) do
    start = System.monotonic_time(:millisecond)

    register_before_send(conn, fn conn ->
      ApiLog.record(%{
        at: DateTime.utc_now(),
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        status: conn.status,
        duration_ms: System.monotonic_time(:millisecond) - start,
        board: board_info(conn),
        remote_ip: format_ip(conn.remote_ip),
        params: sanitize_params(conn.params)
      })

      conn
    end)
  end

  defp board_info(conn) do
    case conn.assigns[:current_board] do
      %{name: name, key: key} -> %{name: name, key: key}
      _ -> nil
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(_), do: nil

  defp sanitize_params(%Plug.Conn.Unfetched{}), do: nil

  defp sanitize_params(params) do
    params |> inspect(limit: 50, printable_limit: @params_limit) |> String.slice(0, @params_limit)
  end
end
