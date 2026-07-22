defmodule Relay.Runs.ExecutorStatusTest do
  use Relay.DataCase, async: true

  alias Relay.Runs

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    %{board: board, stage: stage}
  end

  # Builds a persisted active job on `board`, held by `executor_name`.
  defp active_job(board, stage, executor_name, opts) do
    card = insert(:card, stage: stage, title: opts[:title] || "Do the thing")
    run = insert(:run, card: card)
    ne = insert(:node_execution, run: run, node_key: opts[:node_key] || "implement")

    job =
      insert(:node_job,
        node_execution: ne,
        executor_name: executor_name,
        state: opts[:state] || :claimed,
        payload: %{"isolation" => opts[:isolation] || "shared_clean"}
      )

    %{card: card, job: job, board: board}
  end

  describe "executor_freshness/2" do
    test "is :fresh up to 1.5 × interval" do
      now = DateTime.utc_now()
      e = %Schemas.Executor{interval: 30, last_heartbeat: DateTime.add(now, -44, :second)}

      assert Runs.executor_freshness(e, now) == :fresh
    end

    test "is :stale past 1.5 × interval but before the reclaim threshold" do
      now = DateTime.utc_now()
      e = %Schemas.Executor{interval: 30, last_heartbeat: DateTime.add(now, -50, :second)}

      assert Runs.executor_freshness(e, now) == :stale
      refute Runs.executor_stale?(e, now)
    end

    test "is :gone exactly when executor_stale?/2 is true — one threshold, two consumers" do
      now = DateTime.utc_now()
      e = %Schemas.Executor{interval: 30, last_heartbeat: DateTime.add(now, -61, :second)}

      assert Runs.executor_freshness(e, now) == :gone
      assert Runs.executor_stale?(e, now)
    end

    test "a nil interval falls back to 30s" do
      now = DateTime.utc_now()
      e = %Schemas.Executor{interval: nil, last_heartbeat: DateTime.add(now, -10, :second)}

      assert Runs.executor_freshness(e, now) == :fresh
    end
  end

  describe "list_executor_status/2" do
    test "returns the board's executors by name with host, interval and freshness",
         %{board: board} do
      now = DateTime.utc_now()
      insert(:executor, board: board, name: "zed", host: "zed.local")
      insert(:executor, board: board, name: "amy", host: "amy.local")

      assert [amy, zed] = Runs.list_executor_status(board, now)
      assert amy.name == "amy"
      assert amy.host == "amy.local"
      assert amy.interval == 30
      assert amy.freshness == :fresh
      assert zed.name == "zed"
    end

    test "pools carry the advertised total and a used count from active jobs",
         %{board: board, stage: stage} do
      now = DateTime.utc_now()
      insert(:executor, board: board, name: "e1", capacity: %{"shared_clean" => 3, "exclusive" => 1})
      active_job(board, stage, "e1", isolation: "shared_clean")
      active_job(board, stage, "e1", isolation: "shared_clean")
      active_job(board, stage, "e1", isolation: "exclusive")

      assert [%{pools: pools}] = Runs.list_executor_status(board, now)

      assert pools == [
               %{name: "exclusive", used: 1, total: 1},
               %{name: "shared_clean", used: 2, total: 3}
             ]
    end

    test "any non-exclusive isolation counts as shared_clean", %{board: board, stage: stage} do
      now = DateTime.utc_now()
      insert(:executor, board: board, name: "e1", capacity: %{"shared_clean" => 2})
      active_job(board, stage, "e1", isolation: "worktree")
      active_job(board, stage, "e1", isolation: nil)

      assert [%{pools: [%{name: "shared_clean", used: 2, total: 2}]}] =
               Runs.list_executor_status(board, now)
    end

    test "a job whose class was never advertised still lists, but invents no chip",
         %{board: board, stage: stage} do
      now = DateTime.utc_now()
      insert(:executor, board: board, name: "e1", capacity: %{"shared_clean" => 1})
      active_job(board, stage, "e1", isolation: "exclusive")

      assert [%{pools: pools, jobs: jobs}] = Runs.list_executor_status(board, now)
      assert pools == [%{name: "shared_clean", used: 0, total: 1}]
      assert [%{isolation: "exclusive"}] = jobs
    end

    test "jobs carry the card ref, title, node key and state", %{board: board, stage: stage} do
      now = DateTime.utc_now()
      insert(:executor, board: board, name: "e1")

      %{card: card, job: job} =
        active_job(board, stage, "e1", node_key: "implement", title: "Ship it", state: :running)

      assert [%{jobs: [listed]}] = Runs.list_executor_status(board, now)
      assert listed.job_id == job.id
      assert listed.ref == "#{board.key}#{card.ref_number}"
      assert listed.title == "Ship it"
      assert listed.node_key == "implement"
      assert listed.state == :running
    end

    test "finished and revoked jobs are not listed", %{board: board, stage: stage} do
      now = DateTime.utc_now()
      insert(:executor, board: board, name: "e1")
      active_job(board, stage, "e1", state: :done)
      active_job(board, stage, "e1", state: :revoked)

      assert [%{jobs: [], pools: pools}] = Runs.list_executor_status(board, now)
      assert Enum.all?(pools, &(&1.used == 0))
    end

    test "executors silent longer than 24h drop off the roster", %{board: board} do
      now = DateTime.utc_now()
      insert(:executor, board: board, name: "dormant", last_heartbeat: DateTime.add(now, -23, :hour))
      insert(:executor, board: board, name: "dead", last_heartbeat: DateTime.add(now, -25, :hour))

      assert ["dormant"] = Enum.map(Runs.list_executor_status(board, now), & &1.name)
    end

    test "a silent executor still on the roster reads :gone", %{board: board} do
      now = DateTime.utc_now()
      insert(:executor, board: board, name: "e1", last_heartbeat: DateTime.add(now, -600, :second))

      assert [%{freshness: :gone}] = Runs.list_executor_status(board, now)
    end

    test "board A never sees board B's executors or jobs", %{board: board} do
      now = DateTime.utc_now()
      other = insert(:board)
      other_stage = insert(:stage, board: other)

      insert(:executor, board: board, name: "shared-name")
      insert(:executor, board: other, name: "shared-name")
      active_job(other, other_stage, "shared-name", isolation: "shared_clean")

      assert [%{name: "shared-name", jobs: []}] = Runs.list_executor_status(board, now)
      assert [%{name: "shared-name", jobs: [_one]}] = Runs.list_executor_status(other, now)
    end

    test "defaults `now` to the current clock when omitted", %{board: board} do
      insert(:executor, board: board, name: "e1")

      assert [%{freshness: :fresh}] = Runs.list_executor_status(board)
    end
  end

  describe "display_state (RLY-191)" do
    setup %{board: board}, do: {:ok, board: board, now: DateTime.utc_now()}

    test "a fresh, current executor is :fresh", %{board: board, now: now} do
      insert(:executor, board: board, name: "a", version: Runs.min_executor_version(), last_heartbeat: now)
      assert [%{display_state: :fresh, freshness: :fresh}] = Runs.list_executor_status(board, now)
    end

    test "a beating-but-outdated executor is :outdated, and freshness stays :fresh", %{board: board, now: now} do
      insert(:executor, board: board, name: "a", version: 0, last_heartbeat: now)
      assert [%{display_state: :outdated, freshness: :fresh, outdated: true}] = Runs.list_executor_status(board, now)
    end

    test "staleness outranks outdatedness — a silent, outdated executor is :stale", %{board: board, now: now} do
      # older than 1.5×interval but not yet gone (2×interval / 60s floor)
      insert(:executor,
        board: board,
        name: "a",
        version: 0,
        interval: 30,
        last_heartbeat: DateTime.add(now, -50, :second)
      )

      assert [%{display_state: :stale}] = Runs.list_executor_status(board, now)
    end

    test "a gone executor is :gone regardless of version", %{board: board, now: now} do
      insert(:executor,
        board: board,
        name: "a",
        version: 0,
        interval: 30,
        last_heartbeat: DateTime.add(now, -61, :second)
      )

      assert [%{display_state: :gone}] = Runs.list_executor_status(board, now)
    end
  end
end
