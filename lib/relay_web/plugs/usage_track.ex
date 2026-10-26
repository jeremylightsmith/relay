defmodule RelayWeb.Plugs.UsageTrack do
  @moduledoc """
  Touches the signed-in user's visit on `Relay.Usage.Tracker` for every `GET` through the
  `:browser` pipeline (RE475) — the dead renders and controller pages the `RelayWeb.UsageTrack`
  LiveView hook never sees. Sits right after `:fetch_current_scope`; a signed-out request is
  skipped. A cast, so it never blocks or fails the request, and returns `conn` unchanged.
  """

  alias Relay.Usage.Tracker

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", assigns: %{current_scope: %{user: %Schemas.User{} = user}}} = conn, _opts) do
    Tracker.touch(user, %{})
    conn
  end

  def call(conn, _opts), do: conn
end
