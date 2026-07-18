defmodule Relay.Activity.LogSinkResilienceTest do
  # async: true keeps the sandbox in :manual (non-shared) mode, so a sink that is
  # not the connection owner cannot reach the DB — exactly the state the app-global
  # LogSink is in when a debounced flush fires after a test's sandbox owner has exited.
  use Relay.DataCase, async: true

  alias Relay.Activity.LogSink

  # A flush whose DB query raises must NOT crash the sink: LogSink is a best-effort,
  # fire-and-forget sink (see its moduledoc), and it sits as a :one_for_one sibling of
  # Relay.Repo. A crash storm on a transient DB error trips the supervisor's
  # max_restarts and takes Relay.Repo down with it, cascading into every later test.
  test "a flush that cannot reach the DB drops the batch instead of crashing the sink" do
    sink =
      start_supervised!({LogSink, name: :"log_sink_resil_#{System.unique_integer([:positive])}", debounce_ms: 0})

    ref = Process.monitor(sink)

    entry = %{
      id: System.unique_integer([:monotonic, :positive]),
      ts: DateTime.utc_now(),
      ref: "RLY-7",
      kind: :claude,
      text: "a line",
      run_id: nil
    }

    # board_id 123 need not exist: the sink has no DB access, so resolving the ref
    # raises before any row could match.
    :ok = LogSink.enqueue(123, [entry], sink)

    # Drive the debounce window to completion; the flush runs here.
    _ = :sys.get_state(sink)
    send(sink, :flush)

    refute_receive {:DOWN, ^ref, :process, ^sink, _reason}
    assert %{buffer: [], count: 0} = :sys.get_state(sink)
  end
end
