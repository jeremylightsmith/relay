defmodule Relay.Push.Delivery.Test do
  @moduledoc """
  Test delivery adapter: sends `{:push_delivered, token, payload}` to
  `Application.get_env(:relay, :push_test_pid)`, defaulting to the calling
  process, so a test can assert exactly what went to which device with which
  badge and body.

  Under `config :relay, Relay.Push, async: false` (the `:test` default),
  `Relay.Push` dispatches inline, so "the caller" **is** the test process
  (and its Ecto sandbox connection) and the default applies. A test that
  exercises the real `async: true` path dispatches from a `Task` — a
  different process — so it must set `:push_test_pid` to `self()` first so
  the message still reaches it.
  """

  @behaviour Relay.Push.Delivery

  @impl Relay.Push.Delivery
  def deliver(token, payload) do
    pid = Application.get_env(:relay, :push_test_pid, self())
    send(pid, {:push_delivered, token, payload})
    :ok
  end
end
