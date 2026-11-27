defmodule Hamaca.Runs.StoppedWorkTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Runs

  setup do
    start_capacity!()
    board = insert(:board)
    queue = insert(:stage, board: board, name: "Plan:Done", position: 1, type: :queue)
    works = insert(:stage, board: board, name: "Code", position: 2, type: :work)
    insert(:flow, board: board, key: "code", enabled: true, stage_id: works.id)
    {:ok, board: board, queue: queue, works: works}
  end

  # A queued, unclaimed node-job on this board, inserted `age_s` ago.
  defp queued_job(works, age_s) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    at = DateTime.add(now, -age_s, :second)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running)
    exec = insert(:node_execution, run: run, outcome: nil, finished_at: nil, inserted_at: at)
    insert(:node_job, node_execution: exec, state: :queued, runner_name: nil, claimed_at: nil, inserted_at: at)
  end

  test "nil when the board is quiet — no queued jobs", %{board: board} do
    assert Runs.stopped_work(board) == nil
  end

  test "nil when jobs are queued but every runner is busy and current (criterion 4)", %{board: board, works: works} do
    queued_job(works, 600)
    # A fresh, current runner with zero free slots: busy, not stopped.
    insert(:runner,
      board: board,
      name: "busy",
      version: Runs.min_runner_version(),
      capacity: %{"shared_clean" => 0, "exclusive" => 0}
    )

    assert Runs.stopped_work(board) == nil
  end

  test ":runner_outdated with the version pair when the only runner is refused", %{board: board, works: works} do
    queued_job(works, 600)
    insert(:runner, board: board, name: "old", version: 0)

    assert %{reason: :runner_outdated, detail: detail, queued_count: 1, evidence: evidence} =
             Runs.stopped_work(board)

    assert detail =~ "No jobs claimed in"
    assert detail =~ "requires v#{Runs.min_runner_version()}"
    assert evidence.required_version == Runs.min_runner_version()
  end

  describe "RE482: ./relay stragglers" do
    test "names the one ./relay runner when it is the only refused runner", %{board: board, works: works} do
      queued_job(works, 720)
      runner = insert(:runner, board: board, name: "studio-mac", cli: "relay", version: 93)

      assert %{reason: :runner_outdated, detail: detail, evidence: evidence} = Runs.stopped_work(board)
      assert evidence.pre_rename_runners == [%{id: runner.id, name: "studio-mac"}]

      assert detail ==
               "No jobs claimed in 12m · Runner studio-mac is still installed as ./relay, which this board " <>
                 "no longer accepts. Update it to ./hamaca and restart."
    end

    test "names several ./relay runners sorted by name", %{board: board, works: works} do
      queued_job(works, 720)
      b = insert(:runner, board: board, name: "b-box", cli: "relay", version: 93)
      a = insert(:runner, board: board, name: "a-box", cli: "relay", version: 93)

      assert %{reason: :runner_outdated, detail: detail, evidence: evidence} = Runs.stopped_work(board)
      assert evidence.pre_rename_runners == [%{id: a.id, name: "a-box"}, %{id: b.id, name: "b-box"}]
      assert String.starts_with?(detail, "No jobs claimed in 12m · Runners a-box, b-box are still installed as ./relay")
      assert String.ends_with?(detail, "Update them to ./hamaca and restart.")
    end

    test "keeps the generic copy when a ./relay runner shares the roster with an old ./hamaca one", %{
      board: board,
      works: works
    } do
      queued_job(works, 720)
      insert(:runner, board: board, name: "relay-box", cli: "relay", version: 93)
      insert(:runner, board: board, name: "old-box", cli: "hamaca", version: Runs.min_runner_version() - 1)

      assert %{reason: :runner_outdated, detail: detail, evidence: evidence} = Runs.stopped_work(board)
      refute Map.has_key?(evidence, :pre_rename_runners)
      assert String.starts_with?(detail, "No jobs claimed in 12m · every connected runner is running old code")
    end

    test "keeps the generic copy when no refused runner is a ./relay install", %{board: board, works: works} do
      queued_job(works, 720)
      insert(:runner, board: board, name: "old-box", cli: "hamaca", version: Runs.min_runner_version() - 1)

      assert %{reason: :runner_outdated, detail: detail, evidence: evidence} = Runs.stopped_work(board)
      refute Map.has_key?(evidence, :pre_rename_runners)
      assert String.starts_with?(detail, "No jobs claimed in 12m · every connected runner is running old code")
    end
  end

  test ":no_runner on an empty roster", %{board: board, works: works} do
    queued_job(works, 600)

    assert %{reason: :no_runner, detail: detail} = Runs.stopped_work(board)
    assert detail =~ "no runner is connected"
  end

  test ":runner_gone when the roster's runners have all gone silent", %{board: board, works: works} do
    queued_job(works, 600)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    insert(:runner,
      board: board,
      name: "silent",
      version: Runs.min_runner_version(),
      last_heartbeat: DateTime.add(now, -3600, :second)
    )

    assert %{reason: :runner_gone} = Runs.stopped_work(board)
  end

  test ":runner_rate_limited when every connected runner is paused at its usage limits", %{board: board, works: works} do
    queued_job(works, 600)
    resets_at = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), 3600, :second)

    insert(:runner,
      board: board,
      name: "paused",
      harnesses: [
        runner_harness("claude-code", usage: paused_usage(resets_at)),
        runner_harness("codex", usage: paused_usage(DateTime.add(resets_at, 600, :second)))
      ]
    )

    assert %{reason: :runner_rate_limited, detail: detail, evidence: evidence} = Runs.stopped_work(board)
    assert detail =~ "No jobs claimed in 10m"
    assert detail =~ "every connected runner is paused at its usage limits (claude-code 5h 95% / 90%)"
    assert detail =~ "resumes #{Runs.resume_time_label(resets_at)}."
    assert evidence.resumes_at == resets_at
  end

  test "nil when a paused runner has a connected, unpaused peer", %{board: board, works: works} do
    queued_job(works, 600)

    insert(:runner,
      board: board,
      name: "paused",
      harnesses: [runner_harness("claude-code", usage: paused_usage(in_an_hour()))]
    )

    insert(:runner, board: board, name: "free")

    assert Runs.stopped_work(board) == nil
  end

  test "RE436: nil when the only runner still has one unpaused harness", %{board: board, works: works} do
    # Not rate limited, so the roster reads :awaiting_capacity — which never stops work.
    queued_job(works, 600)

    insert(:runner,
      board: board,
      name: "half-paused",
      harnesses: [runner_harness("claude-code", usage: paused_usage(in_an_hour())), runner_harness("codex")]
    )

    assert Runs.stopped_work(board) == nil
  end

  defp in_an_hour, do: DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), 3600, :second)

  test "nil when the oldest queued job is younger than the threshold", %{board: board, works: works} do
    queued_job(works, 30)
    insert(:runner, board: board, name: "old", version: 0)

    assert Runs.stopped_work(board) == nil
  end

  # The verdict is polled on the Runners view's 10s tick, so the expensive half — the scheduler
  # snapshot (a full card list + stage/flow/run/runner reads) — must sit BEHIND the age guard,
  # not in front of it. Otherwise a busy board with anything queued pays for a snapshot every tick.
  test "builds no scheduler snapshot while the oldest queued job is under the threshold", %{board: board, works: works} do
    queued_job(works, 30)
    insert(:runner, board: board, name: "old", version: 0)

    {verdict, sources} = with_query_sources(fn -> Runs.stopped_work(board) end)

    assert verdict == nil
    # `runners` and `stages` are read only by `Scheduler.Server.build_snapshot/2`.
    refute "runners" in sources
    refute "stages" in sources
  end

  test "still builds the snapshot once the oldest queued job passes the threshold", %{board: board, works: works} do
    queued_job(works, 600)
    insert(:runner, board: board, name: "old", version: 0)

    {verdict, sources} = with_query_sources(fn -> Runs.stopped_work(board) end)

    assert %{reason: :runner_outdated} = verdict
    assert "runners" in sources
  end

  # Ecto's repo telemetry runs in the process that issued the query, so filtering on the test pid
  # keeps this safe under `async: true`.
  defp with_query_sources(fun) do
    parent = self()
    handler_id = {__MODULE__, parent}

    :telemetry.attach(
      handler_id,
      [:hamaca, :repo, :query],
      fn _event, _measurements, meta, ^parent ->
        if self() == parent, do: send(parent, {:query_source, meta[:source]})
      end,
      parent
    )

    try do
      {fun.(), drain_sources([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_sources(acc) do
    receive do
      {:query_source, source} -> drain_sources([source | acc])
    after
      0 -> acc
    end
  end
end
