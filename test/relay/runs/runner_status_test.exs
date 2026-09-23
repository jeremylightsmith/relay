defmodule Relay.Runs.RunnerStatusTest do
  use Relay.DataCase, async: true

  alias Relay.Runs

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    %{board: board, stage: stage}
  end

  # Builds a persisted active job on `board`, held by `runner_name`.
  defp active_job(board, stage, runner_name, opts) do
    card = insert(:card, stage: stage, title: opts[:title] || "Do the thing")
    run = insert(:run, card: card)
    ne = insert(:node_execution, run: run, node_key: opts[:node_key] || "implement")

    job =
      insert(:node_job,
        node_execution: ne,
        runner_name: runner_name,
        state: opts[:state] || :claimed,
        payload: %{"isolation" => opts[:isolation] || "shared_clean"}
      )

    %{card: card, job: job, board: board}
  end

  describe "runner_freshness/2" do
    test "is :fresh up to 1.5 × interval" do
      now = DateTime.utc_now()
      e = %Schemas.Runner{interval: 30, last_heartbeat: DateTime.add(now, -44, :second)}

      assert Runs.runner_freshness(e, now) == :fresh
    end

    test "is :stale past 1.5 × interval but before the reclaim threshold" do
      now = DateTime.utc_now()
      e = %Schemas.Runner{interval: 30, last_heartbeat: DateTime.add(now, -50, :second)}

      assert Runs.runner_freshness(e, now) == :stale
      refute Runs.runner_stale?(e, now)
    end

    test "is :gone exactly when runner_stale?/2 is true — one threshold, two consumers" do
      now = DateTime.utc_now()
      e = %Schemas.Runner{interval: 30, last_heartbeat: DateTime.add(now, -61, :second)}

      assert Runs.runner_freshness(e, now) == :gone
      assert Runs.runner_stale?(e, now)
    end

    test "a nil interval falls back to 30s" do
      now = DateTime.utc_now()
      e = %Schemas.Runner{interval: nil, last_heartbeat: DateTime.add(now, -10, :second)}

      assert Runs.runner_freshness(e, now) == :fresh
    end
  end

  describe "list_runner_status/2" do
    test "returns the board's runners by name with host, interval and freshness",
         %{board: board} do
      now = DateTime.utc_now()
      insert(:runner, board: board, name: "zed", host: "zed.local")
      insert(:runner, board: board, name: "amy", host: "amy.local")

      assert [amy, zed] = Runs.list_runner_status(board, now)
      assert amy.name == "amy"
      assert amy.host == "amy.local"
      assert amy.interval == 30
      assert amy.freshness == :fresh
      assert zed.name == "zed"
    end

    test "pools carry the advertised total, exclusive used from held and shared used from active jobs",
         %{board: board, stage: stage} do
      now = DateTime.utc_now()

      # RE311: `exclusive` occupancy comes from declared holdings, not the active-job count.
      # No exclusive active job exists here at all — the exclusive chip's `used: 1` can only
      # come from the `held` entry below, which is the point: an exclusive job with no
      # matching `held` entry no longer moves the chip.
      insert(:runner,
        board: board,
        name: "e1",
        capacity: %{"shared_clean" => 3, "exclusive" => 1},
        held: [%{"ref" => "X1", "state" => "bound"}]
      )

      active_job(board, stage, "e1", isolation: "shared_clean")
      active_job(board, stage, "e1", isolation: "shared_clean")

      assert [%{pools: pools}] = Runs.list_runner_status(board, now)

      assert pools == [
               %{name: "exclusive", used: 1, total: 1},
               %{name: "shared_clean", used: 2, total: 3}
             ]
    end

    test "any non-exclusive isolation counts as shared_clean", %{board: board, stage: stage} do
      now = DateTime.utc_now()
      insert(:runner, board: board, name: "e1", capacity: %{"shared_clean" => 2})
      active_job(board, stage, "e1", isolation: "worktree")
      active_job(board, stage, "e1", isolation: nil)

      assert [%{pools: [%{name: "shared_clean", used: 2, total: 2}]}] =
               Runs.list_runner_status(board, now)
    end

    test "a job whose class was never advertised still lists, but invents no chip",
         %{board: board, stage: stage} do
      now = DateTime.utc_now()
      insert(:runner, board: board, name: "e1", capacity: %{"shared_clean" => 1})
      active_job(board, stage, "e1", isolation: "exclusive")

      assert [%{pools: pools, jobs: jobs}] = Runs.list_runner_status(board, now)
      assert pools == [%{name: "shared_clean", used: 0, total: 1}]
      assert [%{isolation: "exclusive"}] = jobs
    end

    test "jobs carry the card ref, title, node key and state", %{board: board, stage: stage} do
      now = DateTime.utc_now()
      insert(:runner, board: board, name: "e1")

      %{card: card, job: job} =
        active_job(board, stage, "e1", node_key: "implement", title: "Ship it", state: :claimed)

      assert [%{jobs: [listed]}] = Runs.list_runner_status(board, now)
      assert listed.job_id == job.id
      assert listed.ref == "#{board.key}#{card.ref_number}"
      assert listed.title == "Ship it"
      assert listed.node_key == "implement"
      assert listed.state == :claimed
    end

    test "finished and revoked jobs are not listed", %{board: board, stage: stage} do
      now = DateTime.utc_now()
      insert(:runner, board: board, name: "e1")
      active_job(board, stage, "e1", state: :done)
      active_job(board, stage, "e1", state: :revoked)

      assert [%{jobs: [], pools: pools}] = Runs.list_runner_status(board, now)
      assert Enum.all?(pools, &(&1.used == 0))
    end

    test "runners silent longer than 24h drop off the roster", %{board: board} do
      now = DateTime.utc_now()
      insert(:runner, board: board, name: "dormant", last_heartbeat: DateTime.add(now, -23, :hour))
      insert(:runner, board: board, name: "dead", last_heartbeat: DateTime.add(now, -25, :hour))

      assert ["dormant"] = Enum.map(Runs.list_runner_status(board, now), & &1.name)
    end

    test "a silent runner still on the roster reads :gone", %{board: board} do
      now = DateTime.utc_now()
      insert(:runner, board: board, name: "e1", last_heartbeat: DateTime.add(now, -600, :second))

      assert [%{freshness: :gone}] = Runs.list_runner_status(board, now)
    end

    test "board A never sees board B's runners or jobs", %{board: board} do
      now = DateTime.utc_now()
      other = insert(:board)
      other_stage = insert(:stage, board: other)

      insert(:runner, board: board, name: "shared-name")
      insert(:runner, board: other, name: "shared-name")
      active_job(other, other_stage, "shared-name", isolation: "shared_clean")

      assert [%{name: "shared-name", jobs: []}] = Runs.list_runner_status(board, now)
      assert [%{name: "shared-name", jobs: [_one]}] = Runs.list_runner_status(other, now)
    end

    test "defaults `now` to the current clock when omitted", %{board: board} do
      insert(:runner, board: board, name: "e1")

      assert [%{freshness: :fresh}] = Runs.list_runner_status(board)
    end
  end

  describe "display_state (RLY-191)" do
    setup %{board: board}, do: {:ok, board: board, now: DateTime.utc_now()}

    test "a fresh, current runner is :fresh", %{board: board, now: now} do
      insert(:runner, board: board, name: "a", version: Runs.min_runner_version(), last_heartbeat: now)
      assert [%{display_state: :fresh, freshness: :fresh}] = Runs.list_runner_status(board, now)
    end

    test "a beating-but-outdated runner is :outdated, and freshness stays :fresh", %{board: board, now: now} do
      insert(:runner, board: board, name: "a", version: 0, last_heartbeat: now)
      assert [%{display_state: :outdated, freshness: :fresh, outdated: true}] = Runs.list_runner_status(board, now)
    end

    test "staleness outranks outdatedness — a silent, outdated runner is :stale", %{board: board, now: now} do
      # older than 1.5×interval but not yet gone (2×interval / 60s floor)
      insert(:runner,
        board: board,
        name: "a",
        version: 0,
        interval: 30,
        last_heartbeat: DateTime.add(now, -50, :second)
      )

      assert [%{display_state: :stale}] = Runs.list_runner_status(board, now)
    end

    test "a gone runner is :gone regardless of version", %{board: board, now: now} do
      insert(:runner,
        board: board,
        name: "a",
        version: 0,
        interval: 30,
        last_heartbeat: DateTime.add(now, -61, :second)
      )

      assert [%{display_state: :gone}] = Runs.list_runner_status(board, now)
    end
  end

  describe "held occupancy (RE311)" do
    test "the exclusive chip counts DECLARED HOLDINGS, not active jobs", %{board: board} do
      # The incident's Bug 3 at the operator's level: a bound-but-idle worktree holds an
      # exclusive partition and has no active job, so the old count read 0/1 — "runner
      # available" — while the runner had zero free exclusive slots.
      insert(:runner,
        board: board,
        name: "holder",
        capacity: %{"shared_clean" => 3, "exclusive" => 2},
        held: [%{"ref" => "TH77", "state" => "bound"}, %{"ref" => "TH8", "state" => "retained"}]
      )

      [runner] = Runs.list_runner_status(board)
      exclusive = Enum.find(runner.pools, &(&1.name == "exclusive"))

      # `retained` holds no partition, so it does not count against the chip.
      assert exclusive.used == 1
      assert exclusive.total == 2
      assert runner.held == [%{"ref" => "TH77", "state" => "bound"}, %{"ref" => "TH8", "state" => "retained"}]
    end

    test "the exclusive chip never reads BELOW the active exclusive job count", %{board: board, stage: stage} do
      # The window between a runner's first exclusive claim and the beat that declares the
      # holding: `held` is one short, and `free_slot?/2` reads this same number — an under-count
      # there blames `:job_awaiting_slot` on a runner that has room, and a runner that has
      # not reported `held` at all would render 0/N while running exclusive jobs.
      insert(:runner, board: board, name: "claimer", capacity: %{"shared_clean" => 2, "exclusive" => 2}, held: [])
      active_job(board, stage, "claimer", isolation: "exclusive")

      [runner] = Runs.list_runner_status(board)
      assert Enum.find(runner.pools, &(&1.name == "exclusive")).used == 1
    end

    test "the shared_clean chip still counts active jobs", %{board: board, stage: stage} do
      # Holdings describe per-card worktrees only, so the shared chip's rule is unchanged.
      insert(:runner, board: board, name: "sharer", capacity: %{"shared_clean" => 2, "exclusive" => 1})
      active_job(board, stage, "sharer", isolation: "shared_clean")

      [runner] = Runs.list_runner_status(board)
      assert Enum.find(runner.pools, &(&1.name == "shared_clean")).used == 1
    end
  end

  describe "rate limits (RE320)" do
    setup %{board: board}, do: {:ok, board: board, now: DateTime.truncate(DateTime.utc_now(), :second)}

    test "runner_rate_limited?/2 is true only until the window resets", %{now: now} do
      paused = %Schemas.Runner{rate_limit: build(:runner_rate_limit, resets_at: DateTime.add(now, 60, :second))}
      reset = %Schemas.Runner{rate_limit: build(:runner_rate_limit, resets_at: now)}

      assert Runs.runner_rate_limited?(paused, now)
      refute Runs.runner_rate_limited?(reset, now)
      refute Runs.runner_rate_limited?(%Schemas.Runner{rate_limit: nil}, now)
    end

    test "a fresh, current, paused runner is :rate_limited and carries its pause", %{board: board, now: now} do
      resets_at = DateTime.add(now, 3600, :second)

      insert(:runner,
        board: board,
        name: "a",
        last_heartbeat: now,
        rate_limit: build(:runner_rate_limit, resets_at: resets_at)
      )

      assert [%{display_state: :rate_limited, freshness: :fresh, rate_limit: rate_limit}] =
               Runs.list_runner_status(board, now)

      assert rate_limit == %{window: "five_hour", utilization: 0.95, max: 0.9, resets_at: resets_at, reason: "limit"}
    end

    test "outdatedness outranks the pause", %{board: board, now: now} do
      insert(:runner, board: board, name: "a", version: 0, last_heartbeat: now, rate_limit: build(:runner_rate_limit))

      assert [%{display_state: :outdated}] = Runs.list_runner_status(board, now)
    end

    test "a pause past its reset reads :fresh with no rate_limit, before any beat clears it",
         %{board: board, now: now} do
      insert(:runner,
        board: board,
        name: "a",
        last_heartbeat: now,
        rate_limit: build(:runner_rate_limit, resets_at: DateTime.add(now, -1, :second))
      )

      assert [%{display_state: :fresh, rate_limit: nil}] = Runs.list_runner_status(board, now)
    end

    test "roster_rate_limit/2 names the resume time only when every live current runner is paused",
         %{board: board, now: now} do
      resets_at = DateTime.add(now, 3600, :second)

      insert(:runner,
        board: board,
        name: "paused",
        last_heartbeat: now,
        rate_limit: build(:runner_rate_limit, resets_at: resets_at)
      )

      assert Runs.roster_rate_limit(board, now) == %{resumes_at: resets_at}

      insert(:runner, board: board, name: "free", last_heartbeat: now)

      assert Runs.roster_rate_limit(board, now) == nil
    end

    test "the phrases the board prints" do
      assert Runs.resume_time_label(~U[2026-09-14 15:40:00Z]) == "3:40 PM UTC"

      assert Runs.rate_limit_phrase(%{window: "five_hour", utilization: 0.95, max: 0.9, reason: "limit"}) ==
               "five_hour 95% / 90%"

      assert Runs.rate_limit_phrase(%{window: "seven_day", utilization: nil, max: nil, reason: "rejected"}) ==
               "Claude refused (seven_day)"
    end
  end

  describe "counting_runner?/1 (RE338)" do
    test "a fresh or stale runner counts; a gone one never does" do
      assert Runs.counting_runner?(%{freshness: :fresh})
      assert Runs.counting_runner?(%{freshness: :stale})
      refute Runs.counting_runner?(%{freshness: :gone})
    end

    test "reads a list_runner_status/2 row directly", %{board: board} do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      insert(:runner, board: board, name: "live", last_heartbeat: now)
      insert(:runner, board: board, name: "silent", last_heartbeat: DateTime.add(now, -600, :second))

      counting = for r <- Runs.list_runner_status(board, now), Runs.counting_runner?(r), do: r.name
      assert counting == ["live"]
    end
  end
end
