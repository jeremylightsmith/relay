defmodule Relay.Push.Delivery do
  @moduledoc """
  The push-delivery seam (RLY-81). Adapters turn a `{device token, payload}`
  pair into an actual notification. Chosen by
  `config :relay, Relay.Push, adapter: <module>`:

    * `Relay.Push.Delivery.Log`  — dev default; logs, no network.
    * `Relay.Push.Delivery.Test` — test default; messages the caller.
    * `Relay.Push.Delivery.APNS` — prod; a real token-based APNs send.

  Delivery is fire-and-forget from the caller's perspective: `Relay.Push`
  ignores the return value beyond logging, so an adapter error can never fail
  the status change that triggered it.
  """

  @callback deliver(token :: String.t(), payload :: map()) :: :ok | {:error, term()}
end
