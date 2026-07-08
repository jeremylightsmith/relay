defmodule RelayWeb.LiveAcceptance do
  @moduledoc """
  `on_mount` hook that lets browser (Playwright) acceptance tests share the
  test's Ecto sandbox connection with the LiveView process.

  Reads the sandbox metadata forwarded on the websocket `:user_agent` and allows
  the LiveView process into the same transaction. Only wired into the router when
  `config :relay, :sql_sandbox` is set (test only) — never in dev or prod.

  See `Phoenix.Ecto.SQL.Sandbox` "Acceptance tests with LiveViews".
  """
  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView, only: [connected?: 1, get_connect_info: 2]

  def on_mount(:default, _params, _session, socket) do
    socket =
      assign_new(socket, :phoenix_ecto_sandbox, fn ->
        if connected?(socket), do: get_connect_info(socket, :user_agent)
      end)

    Phoenix.Ecto.SQL.Sandbox.allow(socket.assigns.phoenix_ecto_sandbox, Ecto.Adapters.SQL.Sandbox)

    {:cont, socket}
  end
end
