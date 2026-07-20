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

  describe "list_executor_status/2" do
    test "reports each runner's version and outdated verdict" do
      board = insert(:board)
      insert(:executor, board: board, name: "current", version: Runs.min_executor_version())
      insert(:executor, board: board, name: "ancient", version: nil)

      by_name = Map.new(Runs.list_executor_status(board), &{&1.name, &1})

      assert by_name["current"].version == Runs.min_executor_version()
      refute by_name["current"].outdated
      assert is_nil(by_name["ancient"].version)
      assert by_name["ancient"].outdated
    end

    test "outdated is orthogonal to freshness — a runner can be both fresh and outdated" do
      board = insert(:board)
      insert(:executor, board: board, name: "ancient", version: nil)

      [runner] = Runs.list_executor_status(board)

      assert runner.freshness == :fresh
      assert runner.outdated
    end
  end

  describe "the floor raised by RLY-193" do
    test "an executor on the last pre-flock build (v12) is refused work" do
      # RLY-193 raised @min_executor_version to the flock build: an executor without the
      # single-process startup lock corrupts worktrees under RLY-170 double-dispatch, so it
      # is genuinely worse than a stopped one and must be refused (the AGENTS.md floor-raise
      # rule). Pinned to >= 13 so a later EXECUTOR_VERSION bump that leaves the floor alone
      # does not break this, while v12 stays the concrete build we now refuse.
      assert Runs.min_executor_version() >= 13
      assert Runs.executor_outdated?(%Schemas.Executor{version: 12})
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
