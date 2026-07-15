defmodule Relay.Push.Delivery.Test do
  @moduledoc """
  Test delivery adapter: sends `{:push_delivered, token, payload}` to the
  calling process, so a test can assert exactly what went to which device with
  which badge and body.

  Relies on `config :relay, Relay.Push, async: false` in `:test`, which makes
  `Relay.Push` dispatch inline instead of under its `Task.Supervisor` — so
  "the caller" **is** the test process (and its Ecto sandbox connection).
  """

  @behaviour Relay.Push.Delivery

  @impl Relay.Push.Delivery
  def deliver(token, payload) do
    send(self(), {:push_delivered, token, payload})
    :ok
  end
end
