defmodule Relay.Push.Delivery.APNS do
  @moduledoc """
  Production delivery: a real token-based APNs send (RLY-81 spec §7).

  `POST https://{host}/3/device/{token}` with the `Relay.Push` §5 payload, where
  host is `api.sandbox.push.apple.com` (dev/TestFlight) or `api.push.apple.com`
  (App Store), chosen by `APNS_ENV`. Auth is the cached ES256 provider JWT
  (`Relay.Push.Delivery.APNS.JWT`).

  Sent with `Req` over `Relay.Push.APNSFinch`, a dedicated HTTP/2 Finch pool —
  APNs is HTTP/2-only, and we stay Req-first rather than adding pigeon/FCM.
  Tests inject a `Req.Test` plug via `:apns_req_options`, mirroring
  `Relay.Accounts.GoogleTokenValidator`, so the suite never contacts Apple.

  Priority is always `10` (normal alert): per ADR 0005 / RLY-90 there are **no**
  server-side quiet hours — iOS Do-Not-Disturb / Focus does the suppressing.

  Never raises — the caller is a supervised `Task` under `Relay.Push`.
  """

  @behaviour Relay.Push.Delivery

  alias Relay.Push
  alias Relay.Push.Delivery.APNS.JWT

  require Logger

  @impl Relay.Push.Delivery
  def deliver(token, payload) do
    config = apns_config()

    case Req.post(req(config), url: "/3/device/#{token}", json: payload) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} when status in [400, 410] ->
        maybe_prune(token, status, body)
        {:error, {:apns, status}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[apns] #{status} for #{mask(token)}: #{inspect(body)}")
        {:error, {:apns, status}}

      {:error, reason} ->
        Logger.error("[apns] transport error for #{mask(token)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp req(config) do
    [
      base_url: "https://#{host(config)}",
      finch: Relay.Push.APNSFinch,
      retry: false,
      headers: [
        {"authorization", "bearer " <> JWT.fetch(config)},
        {"apns-topic", Keyword.fetch!(config, :topic)},
        {"apns-push-type", "alert"},
        {"apns-priority", "10"}
      ]
    ]
    |> Keyword.merge(Application.get_env(:relay, :apns_req_options, []))
    |> Req.new()
  end

  defp host(config) do
    case Keyword.get(config, :env) do
      "production" -> "api.push.apple.com"
      _sandbox -> "api.sandbox.push.apple.com"
    end
  end

  defp apns_config do
    :relay
    |> Application.get_env(Push, [])
    |> Keyword.get(:apns, [])
  end

  # Apple says the device is gone: drop the row so we stop paying for it.
  # Any other 400 (a payload bug on our side) leaves the device alone.
  defp maybe_prune(token, 410, body) do
    Logger.info("[apns] 410 Unregistered — pruning #{mask(token)}: #{inspect(body)}")
    Push.delete_device_token(token)
  end

  defp maybe_prune(token, 400, %{"reason" => "BadDeviceToken"} = body) do
    Logger.info("[apns] 400 BadDeviceToken — pruning #{mask(token)}: #{inspect(body)}")
    Push.delete_device_token(token)
  end

  defp maybe_prune(token, status, body) do
    Logger.error("[apns] #{status} for #{mask(token)}: #{inspect(body)}")
    :ok
  end

  defp mask(token) when byte_size(token) > 8, do: String.slice(token, 0, 8) <> "…"
  defp mask(token), do: token
end
