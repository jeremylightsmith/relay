defmodule Hamaca.Push.Delivery.Test do
  @moduledoc """
  Test delivery adapter: sends `{:push_delivered, token, payload}` to the process that asked for
  the push, so a test can assert exactly what went to which device with which badge and body.

  Under `config :hamaca, Hamaca.Push, async: false` (the `:test` default), `Hamaca.Push` dispatches
  inline, so "the caller" **is** the test process and `self()` is right. A test that exercises the
  real `async: true` path dispatches from a `Task` — a different process — but `Task` seeds
  `$callers` with its spawner, so walking `[self() | $callers]` still lands on the test. That is
  the same convention `Ecto.Adapters.SQL.Sandbox` uses to hand that `Task` a DB connection, and it
  replaces the `:push_test_pid` application-env key this adapter used to read (ADR 0009 rule 1).
  """

  @behaviour Hamaca.Push.Delivery

  @impl Hamaca.Push.Delivery
  def deliver(token, payload) do
    send(target(), {:push_delivered, token, payload})
    :ok
  end

  defp target, do: List.last([self() | Process.get(:"$callers", [])])
end
