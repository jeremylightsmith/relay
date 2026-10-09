defmodule Relay.Runs.ResumeTest do
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Relay.Runs.Instance
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Resume Board"})
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    # The scripted runner here runs no real skill, so the card arrives already carrying the
    # fields the shipped spec flow declares it writes (RE244) — otherwise every `succeeded` is
    # rewritten to `failed` by the missing-writes guard.
    {:ok, card} =
      Relay.Cards.create_card(stage, %{
        title: "Survive restarts",
        spec: "# Spec (pre-seeded — the spec flow's brainstorm declares it writes this, RE244)",
        acceptance_criteria: "1. It works."
      })

    :ok = Runs.subscribe(board.id)
    %{board: board, flow: flow, card: card}
  end

  test "an app restart adopts a claimed job — no revoke, no new attempt, the runner reports normally",
       %{board: board, flow: flow, card: card} do
    start_engine!()
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{id: job_id, node_key: "brainstorm"}}
    claimed = claim!(board, "r1")
    assert claimed.id == job_id

    # "Restart the app": the whole engine tree goes down and comes back.
    restart_engine!()

    refute_receive {:revoked, _}, 200
    refute_receive {:dispatched, _}, 200

    assert %NodeJob{state: :claimed, runner_name: "r1"} = Repo.get!(NodeJob, job_id)

    assert [%NodeExecution{node_key: "brainstorm", visit: 1, attempt: 1, outcome: nil}] =
             Runs.list_executions(run)

    # The runner that held the job across the restart reports as if nothing happened.
    assert {:ok, %Run{status: :done}} = Runs.report_outcome(claimed, %{outcome: :succeeded, detail: "ok"})
  end

  test "an app restart adopts a queued job — still claimable by a runner that comes up later",
       %{board: board, flow: flow, card: card} do
    start_engine!()
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{id: job_id}}

    restart_engine!()

    refute_receive {:revoked, _}, 200
    refute_receive {:dispatched, _}, 200

    assert %NodeJob{id: ^job_id, state: :queued} = Runs.active_job(run)
    assert [%NodeExecution{}] = Runs.list_executions(run)

    {:ok, late} =
      Runs.upsert_runner(board, %{"name" => "late", "interval" => 30, "capacity" => %{"shared_clean" => 1}})

    assert {:ok, %NodeJob{id: ^job_id, state: :claimed}} = Runs.claim_next_job(late)
  end

  test "an app restart re-enters a running run that has no active job", %{flow: flow, card: card} do
    start_engine!()
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{id: job_id}}
    Runs.revoke_active_jobs(run)
    assert_receive {:revoked, %NodeJob{id: ^job_id}}

    restart_engine!()

    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm", state: :queued} = fresh}
    refute fresh.id == job_id
    assert_receive {:node_started, _run, %NodeExecution{node_key: "brainstorm", visit: 1, attempt: 2}}
  end

  test "boot_mode/1 attaches a run with a queued or claimed job and re-enters one with none",
       %{board: board, flow: flow, card: card} do
    start_engine!()
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{}}

    assert Runs.boot_mode(run) == :attach

    _claimed = claim!(board, "r1")
    assert Runs.boot_mode(run) == :attach

    Runs.revoke_active_jobs(run)
    assert Runs.boot_mode(run) == {:reenter, nil}
  end

  test "after an adopting boot the reaper still requeues a stale runner's shared_clean job",
       %{board: board, flow: flow, card: card} do
    start_engine!()
    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{}}
    claimed = claim!(board, "gone")

    restart_engine!()
    refute_receive {:revoked, _}, 200

    backdate_heartbeat!(board, "gone")
    :ok = Runs.reclaim_stale_runners()

    assert %NodeJob{state: :queued, runner_name: nil} = Repo.get!(NodeJob, claimed.id)
  end

  test "after an adopting boot the reaper still parks an exclusive run whose runner went stale",
       %{board: board, flow: spec_flow} do
    # A stage holds one flow — remove the spec flow so this one can work in Spec.
    {:ok, spec_flow} = Relay.Flows.disable_flow(spec_flow)
    {:ok, _} = Relay.Flows.delete_flow(spec_flow)
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))

    {:ok, excl} =
      Relay.Flows.create_flow(board, %{
        key: "excl",
        isolation: :exclusive,
        stage_id: spec.id,
        nodes: [%{key: "work", type: :agent, run: "work {ref}"}],
        edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
      })

    {:ok, excl} = Relay.Flows.enable_flow(excl)
    {:ok, card} = Relay.Cards.create_card(next_up, %{title: "Exclusive work"})

    start_engine!()
    {:ok, run} = Runs.start_run(card, excl)
    assert_receive {:dispatched, %NodeJob{}}

    {:ok, gone} =
      Runs.upsert_runner(board, %{"name" => "gone2", "interval" => 30, "capacity" => %{"exclusive" => 1}})

    {:ok, claimed} = Runs.claim_next_job(gone)

    restart_engine!()
    refute_receive {:revoked, _}, 200

    backdate_heartbeat!(board, "gone2")
    :ok = Runs.reclaim_stale_runners()

    assert %Run{status: :parked, parked_reason: :runner_gone} = Runs.get_run!(run.id)
    assert %NodeJob{state: :revoked} = Repo.get!(NodeJob, claimed.id)
  end

  test "parked runs stay dormant across restarts — parking never holds a process",
       %{flow: flow, card: card} do
    start_engine!()
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "?", session_id: "s1"})

    restart_engine!()

    refute_receive {:dispatched, _job}, 100
    assert %Run{status: :parked, parked_reason: :needs_input} = Runs.get_run!(run.id)
    assert Registry.lookup(Instance.current().registry, run.id) == []
  end

  test "a second resume_run/2 on an already-resumed run is a detected no-op, not a silent re-write",
       %{flow: flow, card: card} do
    start_engine!()
    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}
    {:ok, parked} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "?", session_id: "s1"})
    assert_receive {:run_parked, _run}

    assert {:ok, %Run{status: :running}} = Runs.resume_run(parked)
    assert_receive {:run_resumed, %Run{status: :running}}
    assert_receive {:dispatched, _job}

    # `parked` is now a stale struct (still shows status: :parked in memory) — a second
    # caller racing on it must be refused, not silently re-write the run or start a
    # second RunServer entry.
    assert {:error, :not_parked} = Runs.resume_run(parked)
    refute_receive {:run_resumed, _}, 100
    refute_receive {:dispatched, _}, 100
  end

  defp claim!(board, name) do
    {:ok, runner} =
      Runs.upsert_runner(board, %{"name" => name, "interval" => 30, "capacity" => %{"shared_clean" => 1}})

    {:ok, %NodeJob{state: :claimed} = claimed} = Runs.claim_next_job(runner)
    claimed
  end

  # Backdate past 2 × interval so the runner reads stale to `runner_stale?/2`.
  defp backdate_heartbeat!(board, name) do
    stale_at = DateTime.utc_now() |> DateTime.add(-1000, :second) |> DateTime.truncate(:second)

    Repo.update_all(
      from(r in Schemas.Runner, where: r.board_id == ^board.id and r.name == ^name),
      set: [last_heartbeat: stale_at]
    )
  end
end
