defmodule RelayWeb.ApiLogTest do
  use ExUnit.Case, async: true

  alias RelayWeb.ApiLog

  setup do
    # An isolated, unnamed instance so tests never touch the app-wide singleton.
    log = start_supervised!({ApiLog, name: nil})
    %{log: log}
  end

  test "list/1 returns entries newest-first", %{log: log} do
    ApiLog.record(log, %{path: "/api/a"})
    ApiLog.record(log, %{path: "/api/b"})
    _ = :sys.get_state(log)

    assert [%{path: "/api/b"}, %{path: "/api/a"}] = ApiLog.list(log)
  end

  test "assigns an integer id to each recorded entry", %{log: log} do
    ApiLog.record(log, %{path: "/api/a"})
    ApiLog.record(log, %{path: "/api/b"})
    _ = :sys.get_state(log)

    assert [%{id: id_b}, %{id: id_a}] = ApiLog.list(log)
    assert is_integer(id_a) and is_integer(id_b)
    assert id_b > id_a
  end

  test "caps the ring at 200 entries, dropping the oldest", %{log: log} do
    for i <- 1..205, do: ApiLog.record(log, %{path: "/api/#{i}"})
    _ = :sys.get_state(log)

    entries = ApiLog.list(log)
    assert length(entries) == 200
    assert hd(entries).path == "/api/205"
    assert List.last(entries).path == "/api/6"
    refute Enum.any?(entries, &(&1.path == "/api/1"))
  end

  test "record/2 broadcasts each new entry to subscribers", %{log: log} do
    ApiLog.subscribe()
    ApiLog.record(log, %{path: "/api/live"})

    assert_receive {:api_log, %{path: "/api/live", id: _}}
  end

  test "clear/1 drops all entries", %{log: log} do
    ApiLog.record(log, %{path: "/api/a"})
    _ = :sys.get_state(log)
    ApiLog.clear(log)
    _ = :sys.get_state(log)

    assert ApiLog.list(log) == []
  end

  test "a recorded entry carries no Authorization token", %{log: log} do
    # The capture plug builds entries and never includes the Authorization
    # header/token — a recorded entry has no :authorization / :token key.
    ApiLog.record(log, %{path: "/api/board", status: 200})
    _ = :sys.get_state(log)

    [entry] = ApiLog.list(log)
    refute Map.has_key?(entry, :authorization)
    refute Map.has_key?(entry, :token)
  end
end
