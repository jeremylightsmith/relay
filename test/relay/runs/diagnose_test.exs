defmodule Relay.Runs.DiagnoseTest do
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Schemas.Run

  setup do
    start_capacity!()
    board = insert(:board)
    queue = insert(:stage, board: board, name: "Plan:Done", position: 1, type: :queue)
    works = insert(:stage, board: board, name: "Code", position: 2, type: :work)
    {:ok, board: board, queue: queue, works: works}
  end

  test "a card no enabled flow pulls from says so", %{board: board, queue: queue} do
    card = insert(:card, stage: queue, status: :ready)

    assert %{verdict: :no_enabled_flow, detail: detail} = Runs.diagnose(board, card)
    assert detail =~ "no enabled flow"
  end

  test "a flow with no connected executor is no_executor", %{board: board, queue: queue, works: works} do
    insert(:flow, board: board, key: "code", enabled: true, pulls_from_stage_id: queue.id, works_in_stage_id: works.id)
    card = insert(:card, stage: queue, status: :ready)

    assert %{verdict: :no_executor, evidence: %{flow_key: "code"}} = Runs.diagnose(board, card)
  end

  test "an outdated-only roster surfaces :executor_outdated through diagnose", %{board: board, queue: queue, works: works} do
    insert(:flow, board: board, key: "code", enabled: true, pulls_from_stage_id: queue.id, works_in_stage_id: works.id)
    insert(:executor, board: board, name: "old", version: 0)
    card = insert(:card, stage: queue, status: :ready)

    assert %{verdict: :executor_outdated, detail: detail, evidence: evidence} = Runs.diagnose(board, card)
    assert detail =~ "requires v#{Runs.min_executor_version()}"
    assert evidence.required_version == Runs.min_executor_version()
  end

  test ":job_stranded still overrides :executor_outdated", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    insert(:executor, board: board, name: "old", version: 0, last_heartbeat: DateTime.add(now, -3600, :second))
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running, current_node: "implement")
    execution = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)

    insert(:node_job,
      node_execution: execution,
      state: :claimed,
      executor_name: "old",
      claimed_at: DateTime.add(now, -3600, :second)
    )

    assert %{verdict: :job_stranded} = Runs.diagnose(board, card, now)
  end

  test "a live run whose job is stuck behind an outdated executor diagnoses as :executor_outdated",
       %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    insert(:executor, board: board, name: "old", version: 0, last_heartbeat: now)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running, current_node: "implement")
    exec = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)
    insert(:node_job, node_execution: exec, state: :queued, executor_name: nil, claimed_at: nil)

    assert %{verdict: :executor_outdated, detail: detail} = Runs.diagnose(board, card, now)
    assert detail =~ "requires v#{Runs.min_executor_version()}"
  end

  # The other side of that branch: once the outdated executor has actually CLAIMED the job it is
  # working it, so the roster-blocked correction must not clobber :run_active with
  # :executor_outdated. The OUTDATED badge on the runners view is the separate, correct signal.
  # Pins job_working?/3's true path, which nothing else exercises (RE255).
  test "a live run whose job is claimed by an outdated-but-beating executor stays run_active",
       %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    insert(:executor, board: board, name: "old", version: 0, last_heartbeat: now)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running, current_node: "implement")
    exec = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)
    insert(:node_job, node_execution: exec, state: :claimed, executor_name: "old", claimed_at: now)

    assert %{verdict: :run_active} = Runs.diagnose(board, card, now)
  end

  test "a failed run names the node and carries the whole failure detail", %{board: board, works: works} do
    card = insert(:card, stage: works, status: :working)
    detail = String.duplicate("boom.\n\n", 400)
    run = insert(:run, card: card, status: :failed, current_node: nil, failure_detail: detail)
    insert(:node_execution, run: run, node_key: "final_review", outcome: :failed, detail: detail)

    assert %{verdict: :run_failed, detail: sentence, evidence: evidence} = Runs.diagnose(board, card)
    assert sentence =~ "final_review"
    assert evidence.last_execution.node_key == "final_review"
    assert evidence.last_execution.outcome == :failed
    assert evidence.last_execution.detail == detail
  end

  test "a claimed job past the grace with a dead executor is stranded", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running, current_node: "implement")
    execution = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)

    insert(:node_job,
      node_execution: execution,
      state: :claimed,
      executor_name: "ghost",
      claimed_at: DateTime.add(now, -3600, :second)
    )

    insert(:executor, board: board, name: "ghost", last_heartbeat: DateTime.add(now, -3600, :second))

    assert %{verdict: :job_stranded, detail: detail, evidence: %{job: job}} = Runs.diagnose(board, card, now)
    assert detail =~ "ghost"
    assert job.state == :claimed
  end

  test "a live run with a fresh executor stays run_active", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :running, current_node: "implement")
    execution = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)
    insert(:node_job, node_execution: execution, state: :claimed, executor_name: "mac", claimed_at: now)
    insert(:executor, board: board, name: "mac", last_heartbeat: now)

    assert %{verdict: :run_active, evidence: %{current_node: "implement"}} = Runs.diagnose(board, card, now)
  end

  # A parked run (run != nil) short-circuits explain/2 to run_verdict before the flow
  # lookup matters, so these tests need no flow — just the run + its pinned executor row.
  test "a parked pinned run names the executor and its freshness", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works, status: :working)

    insert(:run,
      card: card,
      status: :parked,
      parked_reason: :executor_gone,
      current_node: nil,
      pinned_executor_name: "exec-a"
    )

    # exec-a's row exists but its last beat is long past the stale threshold → gone.
    insert(:executor, board: board, name: "exec-a", last_heartbeat: DateTime.add(now, -3600, :second))

    assert %{verdict: :awaiting_capacity, detail: detail, evidence: evidence} = Runs.diagnose(board, card, now)
    assert detail =~ ~s(executor "exec-a")
    assert detail =~ "gone"
    assert evidence.pinned_executor_name == "exec-a"
    assert evidence.pinned_executor_freshness == :gone
  end

  test "a parked pinned run whose executor row is absent says so", %{board: board, works: works} do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    card = insert(:card, stage: works, status: :working)

    insert(:run,
      card: card,
      status: :parked,
      parked_reason: :executor_gone,
      current_node: nil,
      pinned_executor_name: "exec-ghost"
    )

    assert %{detail: detail, evidence: evidence} = Runs.diagnose(board, card, now)
    assert detail =~ "not currently connected"
    assert evidence.pinned_executor_freshness == :absent
  end

  test "a refused parked run is :resume_refused and carries the RE297 evidence", %{board: board, works: works} do
    queue = insert(:stage, board: board, name: "Plan:Done2", position: 3, type: :queue)
    insert(:flow, board: board, key: "code", enabled: true, pulls_from_stage_id: queue.id, works_in_stage_id: works.id)

    card = insert(:card, stage: works, status: :working)
    run = insert(:run, card: card, status: :parked, parked_reason: :executor_gone, current_node: nil)
    since = DateTime.utc_now() |> DateTime.add(-20 * 60, :second) |> DateTime.truncate(:second)
    :ok = Runs.record_resume_refusals(board.id, [%{run_id: run.id, card_id: card.id, reason: :no_isolation}], since)

    assert %{verdict: :resume_refused, detail: detail, evidence: evidence} = Runs.diagnose(board, card)
    assert detail =~ "flow row no longer exists"
    assert detail =~ "It has been refused for 20m."
    assert evidence.resume_refused_reason == :no_isolation
    assert evidence.resume_refused_since == since
    assert evidence.isolation == nil
    assert Map.has_key?(evidence, :pinned_executor_id)
  end

  describe "job_awaiting_slot (RE311)" do
    # A live run on `works` whose current node-job is queued, unclaimed and `age_s` old, carrying
    # the exclusive payload shape `Runs.build_payload/4` produces (the `vars.ref` matters: the
    # detail names the holders, and the same field is what the claim's held-ref bypass reads).
    defp awaiting_card(board, works, now, age_s) do
      at = DateTime.add(now, -age_s, :second)
      card = insert(:card, stage: works, status: :working)
      run = insert(:run, card: card, status: :running, current_node: "final_review")
      execution = insert(:node_execution, run: run, node_key: "final_review", outcome: nil, finished_at: nil)

      job =
        insert(:node_job,
          node_execution: execution,
          state: :queued,
          executor_name: nil,
          claimed_at: nil,
          inserted_at: at,
          payload: %{"isolation" => "exclusive", "vars" => %{"ref" => Relay.Cards.ref(board, card)}}
        )

      {card, job}
    end

    test "a live run whose job has waited past the grace window with a full roster names all three facts",
         %{board: board, works: works} do
      # The incident verdict was `:run_active` — "Run 498 is live and working" — which was true
      # of the run and useless to the operator whose job had been queued 90 minutes.
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {card, job} = awaiting_card(board, works, now, 5_460)

      insert(:executor,
        board: board,
        name: "Jeremy's lappy",
        last_heartbeat: now,
        capacity: %{"shared_clean" => 3, "exclusive" => 2},
        held: [%{"ref" => "TH56", "state" => "bound"}, %{"ref" => "TH77", "state" => "bound"}]
      )

      assert %{verdict: :job_awaiting_slot, detail: detail, evidence: evidence} =
               Runs.diagnose(board, card, now)

      assert detail =~ "Job #{job.id}"
      assert detail =~ "final_review"
      assert detail =~ "91m"
      assert detail =~ "free exclusive slot"
      assert detail =~ ~s("Jeremy's lappy" holds 2 of 2)
      assert detail =~ "TH56 bound, TH77 bound"
      assert evidence.queued_age_s >= 5_460
      assert evidence.isolation == "exclusive"
      assert [%{name: "Jeremy's lappy", used: 2, total: 2}] = evidence.executors
    end

    test "under the grace window the verdict is unchanged", %{board: board, works: works} do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {card, _job} = awaiting_card(board, works, now, 60)

      insert(:executor,
        board: board,
        name: "lappy",
        last_heartbeat: now,
        capacity: %{"exclusive" => 1},
        held: [%{"ref" => "TH1", "state" => "bound"}]
      )

      assert %{verdict: :run_active} = Runs.diagnose(board, card, now)
    end

    test "a free slot in the job's class means this layer never fires", %{board: board, works: works} do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {card, _job} = awaiting_card(board, works, now, 5_460)

      insert(:executor,
        board: board,
        name: "lappy",
        last_heartbeat: now,
        capacity: %{"exclusive" => 2},
        held: [%{"ref" => "TH1", "state" => "bound"}]
      )

      assert %{verdict: :run_active} = Runs.diagnose(board, card, now)
    end

    test "with no executor connected the roster verdict still wins", %{board: board, works: works} do
      # `:no_executor` is the more specific, more actionable answer; this layer must not
      # generalise it into "everyone is busy".
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {card, _job} = awaiting_card(board, works, now, 5_460)

      assert %{verdict: :no_executor} = Runs.diagnose(board, card, now)
    end

    test "an outdated-only roster still diagnoses :executor_outdated", %{board: board, works: works} do
      # A refused executor claims nothing whatever its free slots say, so "no free slot" would be
      # the wrong diagnosis even when it is also full.
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {card, _job} = awaiting_card(board, works, now, 5_460)

      insert(:executor,
        board: board,
        name: "old",
        version: 0,
        last_heartbeat: now,
        capacity: %{"exclusive" => 1},
        held: [%{"ref" => "TH1", "state" => "bound"}]
      )

      assert %{verdict: :executor_outdated} = Runs.diagnose(board, card, now)
    end

    test "a parked run keeps its own specific verdict, even behind an old queued job and a full roster",
         %{board: board, works: works} do
      # Built through awaiting_card/4 so the job WOULD qualify for :job_awaiting_slot on its own
      # (queued, unclaimed, past grace, full roster) — then the run is parked. The
      # `awaiting_slot(%{status: :parked}, ...)` guard must keep this on the run's own parked
      # verdict rather than being clobbered by the awaiting-slot layer.
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {card, _job} = awaiting_card(board, works, now, 5_460)
      run = Relay.Repo.get_by!(Run, card_id: card.id)

      {1, _} =
        Relay.Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: :parked, parked_reason: :needs_input])

      insert(:executor,
        board: board,
        name: "lappy",
        last_heartbeat: now,
        capacity: %{"exclusive" => 1},
        held: [%{"ref" => "TH1", "state" => "bound"}]
      )

      assert %{verdict: :awaiting_listener_resume} = Runs.diagnose(board, card, now)
    end
  end
end
