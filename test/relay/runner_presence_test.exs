defmodule Relay.RunnerPresenceTest do
  use ExUnit.Case, async: true

  alias Relay.RunnerPresence

  # RunnerPresence is started by the application, so we use the running table and
  # isolate tests with unique board_ids (the BoardWatch test pattern) rather than
  # starting our own instance.

  defp board_id, do: System.unique_integer([:positive])

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        "runner_id" => "host-1-abcd",
        "host" => "jeremy-mbp",
        "started_at" => "2026-07-17T08:00:00Z",
        "interval" => 30,
        "pools" => [%{"name" => "clean", "mode" => "shared", "used" => 1, "total" => 3}],
        "jobs" => [
          %{"ref" => "RLY-9", "stage" => "Code", "pool" => "clean", "started_at" => "2026-07-17T08:01:00Z"}
        ],
        "refs" => ["RLY-9"]
      },
      overrides
    )
  end

  test "beat/3 upserts a snapshot and broadcasts {:runner_beat, runner}" do
    id = board_id()
    :ok = RunnerPresence.subscribe(id)

    :ok = RunnerPresence.beat(id, payload())

    assert_receive {:runner_beat, runner}
    assert runner.runner_id == "host-1-abcd"
    assert runner.host == "jeremy-mbp"
    assert runner.interval == 30
    assert [%{name: "clean", mode: :shared, used: 1, total: 3}] = runner.pools
    assert [%{ref: "RLY-9", stage: "Code", pool: "clean", started_at: %DateTime{}}] = runner.jobs
    assert runner.refs == ["RLY-9"]
    assert %DateTime{} = runner.last_beat_at
    assert [%{runner_id: "host-1-abcd"}] = RunnerPresence.list(id)
  end

  test "a second beat replaces the row instead of adding one" do
    id = board_id()
    :ok = RunnerPresence.beat(id, payload())
    :ok = RunnerPresence.beat(id, payload(%{"jobs" => [], "refs" => []}))

    assert [%{jobs: [], refs: []}] = RunnerPresence.list(id)
  end

  test "list/1 is board-scoped and sorted by started_at" do
    a = board_id()
    b = board_id()

    :ok = RunnerPresence.beat(a, payload(%{"runner_id" => "younger", "started_at" => "2026-07-17T09:00:00Z"}))
    :ok = RunnerPresence.beat(a, payload(%{"runner_id" => "older", "started_at" => "2026-07-17T07:00:00Z"}))
    :ok = RunnerPresence.beat(b, payload(%{"runner_id" => "other-board"}))

    assert ["older", "younger"] = Enum.map(RunnerPresence.list(a), & &1.runner_id)
  end

  test "prune/1 drops only rows whose last beat is older than 24 hours" do
    id = board_id()
    now = DateTime.utc_now()

    :ok = RunnerPresence.beat(id, payload(%{"runner_id" => "dead"}), DateTime.add(now, -25, :hour))
    :ok = RunnerPresence.beat(id, payload(%{"runner_id" => "dormant"}), DateTime.add(now, -23, :hour))

    :ok = RunnerPresence.prune(now)

    assert ["dormant"] = Enum.map(RunnerPresence.list(id), & &1.runner_id)
  end

  test "a malformed payload still snapshots with safe defaults" do
    id = board_id()

    :ok =
      RunnerPresence.beat(id, %{
        "runner_id" => "bare",
        "started_at" => "not-a-date",
        "pools" => "nope",
        "jobs" => nil
      })

    assert [runner] = RunnerPresence.list(id)
    assert runner.interval == 30
    assert runner.pools == []
    assert runner.jobs == []
    assert runner.refs == []
    # unparseable started_at falls back to the beat's server clock
    assert runner.started_at == runner.last_beat_at
  end

  # Builds a runner whose last beat was `seconds_ago` before a fixed `now`.
  # Module level — ExUnit forbids defp inside describe.
  defp runner_at(seconds_ago, interval) do
    now = ~U[2026-07-17 12:00:00Z]
    {%{last_beat_at: DateTime.add(now, -seconds_ago, :second), interval: interval}, now}
  end

  describe "freshness/2" do
    test ":fresh up to and including 1.5x the interval" do
      {runner, now} = runner_at(45, 30)
      assert RunnerPresence.freshness(runner, now) == :fresh
    end

    test ":stale just past 1.5x, and at exactly 2x" do
      {runner, now} = runner_at(46, 30)
      assert RunnerPresence.freshness(runner, now) == :stale

      {runner, now} = runner_at(60, 30)
      assert RunnerPresence.freshness(runner, now) == :stale
    end

    test ":gone past two beat intervals" do
      {runner, now} = runner_at(61, 30)
      assert RunnerPresence.freshness(runner, now) == :gone
    end

    test "thresholds scale with the runner's own promised interval" do
      {runner, now} = runner_at(89, 60)
      assert RunnerPresence.freshness(runner, now) == :fresh

      {runner, now} = runner_at(121, 60)
      assert RunnerPresence.freshness(runner, now) == :gone
    end
  end
end
