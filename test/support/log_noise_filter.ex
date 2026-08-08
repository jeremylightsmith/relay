defmodule Relay.TestSupport.LogNoiseFilter do
  @moduledoc """
  A `:logger` primary filter that drops sandbox-teardown log noise which buries the test-suite
  output but which **no test asserts on** (verified by grep before adding any pattern here):

    * `Postgrex.Protocol (...) disconnected: ** (DBConnection.ConnectionError) client ... exited`
      — emitted when an async test checks its sandbox connection back in while a background
      process still has a query in flight. A pure teardown race, never a real failure.
    * `LogSink dropped N buffered log line(s): ...` — `Relay.Activity.LogSink` is best-effort by
      construction, and `log_sink_resilience_test.exs` drives that exact path on purpose (a flush
      with no DB access must drop its batch rather than crash the sink). The same line can also
      appear when a debounced flush fires after its test's sandbox owner has already checked in.

  Installed in `test/test_helper.exs`. A primary filter runs ahead of every handler, including
  `ExUnit.CaptureLog`'s — so ONLY patterns that no `capture_log` test relies on may live here.
  """

  # Substrings that mark a line as teardown noise. Keep this list tiny and never-asserted.
  @noise ["disconnected: ** (DBConnection", "LogSink dropped"]

  @doc "Erlang `:logger` filter: return `:stop` to drop the event, or the event to keep it."
  def filter(%{msg: msg} = event, _extra) do
    if noisy?(render(msg)), do: :stop, else: event
  end

  def filter(event, _extra), do: event

  defp noisy?(text), do: Enum.any?(@noise, &String.contains?(text, &1))

  defp render({:string, chardata}), do: safe_binary(chardata)
  defp render({:report, report}), do: inspect(report)

  defp render({format, args}) when is_list(format) or is_binary(format) do
    format |> :io_lib.format(args) |> safe_binary()
  rescue
    _ -> ""
  end

  defp render(_), do: ""

  defp safe_binary(chardata) do
    IO.iodata_to_binary(chardata)
  rescue
    _ -> ""
  end
end
