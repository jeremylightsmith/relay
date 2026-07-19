defmodule Relay.RunsExecutorVersionTest do
  @moduledoc """
  RLY-184: the server declares the oldest `bin/relay` it will hand work to, and an executor
  below it is outdated. `nil` is outdated by construction — an executor that reports no version
  predates this card, which is definitionally behind, so every currently-running stale process
  is flagged the moment this ships.
  """
  use Relay.DataCase, async: true

  alias Relay.Runs

  describe "executor_outdated?/1" do
    test "an executor reporting no version is outdated" do
      assert Runs.executor_outdated?(%Schemas.Executor{version: nil})
    end

    test "an executor below the minimum is outdated" do
      assert Runs.executor_outdated?(%Schemas.Executor{version: Runs.min_executor_version() - 1})
    end

    test "an executor at the minimum is not outdated" do
      refute Runs.executor_outdated?(%Schemas.Executor{version: Runs.min_executor_version()})
    end

    test "an executor above the minimum is not outdated" do
      refute Runs.executor_outdated?(%Schemas.Executor{version: Runs.min_executor_version() + 1})
    end
  end

  describe "upsert_executor/2" do
    setup do
      %{board: insert(:board)}
    end

    test "carries the reported version through", %{board: board} do
      {:ok, executor} =
        Runs.upsert_executor(board, %{"name" => "mac", "host" => "mac.local", "version" => 4})

      assert executor.version == 4
    end

    test "a non-integer version normalizes to nil rather than raising", %{board: board} do
      # RLY-162's shape lesson: untrusted client input must not 500 the executor's front door,
      # and nil is already the "outdated" value, so degrading is safe and honest.
      {:ok, executor} =
        Runs.upsert_executor(board, %{"name" => "mac", "host" => "m", "version" => "banana"})

      assert is_nil(executor.version)
      assert Runs.executor_outdated?(executor)
    end

    test "a later beat updates the stored version", %{board: board} do
      {:ok, _} = Runs.upsert_executor(board, %{"name" => "mac", "host" => "m", "version" => 1})
      {:ok, executor} = Runs.upsert_executor(board, %{"name" => "mac", "host" => "m", "version" => 2})

      assert executor.version == 2
    end
  end

  describe "the minimum the server requires" do
    test "is never higher than the EXECUTOR_VERSION this checkout's bin/relay declares" do
      # A server requiring a version its own repo cannot supply refuses EVERY executor, and
      # that mistake is otherwise only discoverable at runtime, on a board that has gone quiet.
      source = File.read!("bin/relay")
      [_line, declared] = Regex.run(~r/^EXECUTOR_VERSION = (\d+)$/m, source)

      assert Runs.min_executor_version() <= String.to_integer(declared)
    end
  end
end
