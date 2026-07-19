defmodule Relay.RunsCapabilitiesTest do
  @moduledoc """
  `upsert_executor/2`'s capabilities branch (RLY-182). The subtle bug this guards: the
  original `on_conflict: {:replace, [...]}` replaces with the INSERT's values, so a beat
  that omitted `capabilities` would null out a perfectly good row — and preflight would
  then report every agent as missing on a healthy executor.
  """
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Runs
  alias Schemas.Executor

  setup do
    %{board: insert(:board)}
  end

  defp beat(board, attrs) do
    {:ok, executor} = Runs.upsert_executor(board, Map.merge(%{"name" => "mac-1"}, attrs))
    Repo.get!(Executor, executor.id)
  end

  test "a first beat with no capabilities stores nil, not an empty map", %{board: board} do
    assert beat(board, %{}).capabilities == nil
  end

  test "capabilities are stored normalized: string keys, deduped, sorted", %{board: board} do
    row =
      beat(board, %{
        "capabilities" => %{
          "agents" => ["smoke-tester", "plan-implementer", "smoke-tester"],
          "skills" => ["write-plan", "brainstorm"]
        }
      })

    assert row.capabilities == %{
             "agents" => ["plan-implementer", "smoke-tester"],
             "skills" => ["brainstorm", "write-plan"]
           }
  end

  test "a later beat omitting capabilities leaves the stored value intact", %{board: board} do
    beat(board, %{"capabilities" => %{"agents" => ["final-fixer"], "skills" => []}})
    row = beat(board, %{"capacity" => %{"shared_clean" => 2}})

    assert row.capabilities == %{"agents" => ["final-fixer"], "skills" => []}
    assert row.capacity == %{"shared_clean" => 2}
  end

  test "a malformed capabilities payload is treated as not reported", %{board: board} do
    beat(board, %{"capabilities" => %{"agents" => ["final-fixer"], "skills" => []}})

    assert beat(board, %{"capabilities" => "nope"}).capabilities == %{
             "agents" => ["final-fixer"],
             "skills" => []
           }
  end

  test "non-string names inside the lists are dropped, not stored", %{board: board} do
    row = beat(board, %{"capabilities" => %{"agents" => ["ok", 7, nil], "skills" => "nope"}})

    assert row.capabilities == %{"agents" => ["ok"], "skills" => []}
  end
end
