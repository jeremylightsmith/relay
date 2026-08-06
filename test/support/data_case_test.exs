defmodule Relay.DataCaseTest do
  @moduledoc """
  Exercises `allow!/1`'s shared-mode branch and `restart_engine!/1`'s name-stability contract
  (ADR 0009) directly. Every other `allow!/1` call site in the suite is already `async: true`, so
  it only ever sees `Sandbox.allow/3`'s `:ok` branch — this module stays `async: false` on purpose
  to reach the `:not_found` branch that `Sandbox.allow/3` returns when the caller holds no
  checkout of its own.
  """
  use Relay.DataCase, async: false

  alias Relay.Activity.Pruner

  test "allow!/1 tolerates shared mode and grants the sandbox connection to a supervised child" do
    pruner = allow!(start_supervised!({Pruner, name: :"data_case_pruner_#{System.unique_integer([:positive])}"}))

    send(pruner, :prune)
    :sys.get_state(pruner)

    assert Process.alive?(pruner)
  end

  test "restart_engine!/1 keeps a start_engine!/1 listener override stable across a restart" do
    listener_name = :"data_case_listener_#{System.unique_integer([:positive])}"

    start_engine!(listener: listener_name)
    before_pid = Process.whereis(listener_name)
    assert is_pid(before_pid)

    restart_engine!()

    # Same registered name, but a genuinely new process — not just a survivor that was never
    # stopped. A restart_engine!/1 that silently no-op'd (or failed to stop the old tree) would
    # leave this pid unchanged.
    after_pid = Process.whereis(listener_name)
    assert is_pid(after_pid)
    assert after_pid != before_pid
  end
end
