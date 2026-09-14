defmodule Relay.RunsRunnerVersionTest do
  @moduledoc """
  RLY-184: the server declares the oldest `./relay` it will hand work to, and a runner
  below it is outdated. `nil` is outdated by construction — a runner that reports no version
  predates this card, which is definitionally behind, so every currently-running stale process
  is flagged the moment this ships.
  """
  use Relay.DataCase, async: true

  alias Relay.Runs

  describe "runner_outdated?/1" do
    test "a runner reporting no version is outdated" do
      assert Runs.runner_outdated?(%Schemas.Runner{version: nil})
    end

    test "a runner below the minimum is outdated" do
      assert Runs.runner_outdated?(%Schemas.Runner{version: Runs.min_runner_version() - 1})
    end

    test "a runner at the minimum is not outdated" do
      refute Runs.runner_outdated?(%Schemas.Runner{version: Runs.min_runner_version()})
    end

    test "a runner above the minimum is not outdated" do
      refute Runs.runner_outdated?(%Schemas.Runner{version: Runs.min_runner_version() + 1})
    end
  end

  describe "upsert_runner/2" do
    setup do
      %{board: insert(:board)}
    end

    test "carries the reported version through", %{board: board} do
      {:ok, runner} =
        Runs.upsert_runner(board, %{"name" => "mac", "host" => "mac.local", "version" => 4})

      assert runner.version == 4
    end

    test "a non-integer version normalizes to nil rather than raising", %{board: board} do
      # RLY-162's shape lesson: untrusted client input must not 500 the runner's front door,
      # and nil is already the "outdated" value, so degrading is safe and honest.
      {:ok, runner} =
        Runs.upsert_runner(board, %{"name" => "mac", "host" => "m", "version" => "banana"})

      assert is_nil(runner.version)
      assert Runs.runner_outdated?(runner)
    end

    test "a later beat updates the stored version", %{board: board} do
      {:ok, _} = Runs.upsert_runner(board, %{"name" => "mac", "host" => "m", "version" => 1})
      {:ok, runner} = Runs.upsert_runner(board, %{"name" => "mac", "host" => "m", "version" => 2})

      assert runner.version == 2
    end
  end

  describe "list_runner_status/2" do
    test "reports each runner's version and outdated verdict" do
      board = insert(:board)
      insert(:runner, board: board, name: "current", version: Runs.min_runner_version())
      insert(:runner, board: board, name: "ancient", version: nil)

      by_name = Map.new(Runs.list_runner_status(board), &{&1.name, &1})

      assert by_name["current"].version == Runs.min_runner_version()
      refute by_name["current"].outdated
      assert is_nil(by_name["ancient"].version)
      assert by_name["ancient"].outdated
    end

    test "outdated is orthogonal to freshness — a runner can be both fresh and outdated" do
      board = insert(:board)
      insert(:runner, board: board, name: "ancient", version: nil)

      [runner] = Runs.list_runner_status(board)

      assert runner.freshness == :fresh
      assert runner.outdated
    end
  end

  describe "the floor raised by RLY-193" do
    test "a runner on the last pre-flock build (v12) is refused work" do
      # RLY-193 raised @min_runner_version to the flock build: a runner without the
      # single-process startup lock corrupts worktrees under RLY-170 double-dispatch, so it
      # is genuinely worse than a stopped one and must be refused (the AGENTS.md floor-raise
      # rule). Pinned to >= 13 so a later RUNNER_VERSION bump that leaves the floor alone
      # does not break this, while v12 stays the concrete build we now refuse.
      assert Runs.min_runner_version() >= 13
      assert Runs.runner_outdated?(%Schemas.Runner{version: 12})
    end
  end

  describe "the minimum the server requires" do
    test "is never higher than the RUNNER_VERSION this checkout's ./relay declares" do
      # A server requiring a version its own repo cannot supply refuses EVERY runner, and
      # that mistake is otherwise only discoverable at runtime, on a board that has gone quiet.
      source = File.read!("relay")
      [_line, declared] = Regex.run(~r/^RUNNER_VERSION = (\d+)$/m, source)

      assert Runs.min_runner_version() <= String.to_integer(declared)
    end

    test "the talk floor is never below the base floor" do
      # The factory and the runner contract fixture both use the talk floor as "a fully
      # current runner". If the base floor ever passed it, every one of them would 409.
      assert Runs.min_talk_runner_version() >= Runs.min_runner_version()
    end
  end
end
