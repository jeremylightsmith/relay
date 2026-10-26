defmodule Hamaca.Push.Delivery.Log do
  @moduledoc """
  Dev/default delivery adapter: logs the notification instead of sending it, so
  the whole trigger→recipient→dispatch pipeline is exercisable without Apple
  credentials.
  """

  @behaviour Hamaca.Push.Delivery

  require Logger

  @impl Hamaca.Push.Delivery
  def deliver(token, payload) do
    Logger.info("[push] → #{mask(token)} #{inspect(payload)}")
    :ok
  end

  defp mask(token) when byte_size(token) > 8, do: String.slice(token, 0, 8) <> "…"
  defp mask(token), do: token
end
