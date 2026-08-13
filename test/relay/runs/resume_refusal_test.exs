defmodule Relay.Runs.ResumeRefusalTest do
  use Relay.DataCase, async: false

  import Ecto.Query

  alias Relay.Runs
  alias Relay.Runs.Scheduler
  alias Relay.Runs.Scheduler.RunsEngine
  alias Relay.Runs.Scheduler.Server
  alias Schemas.Run

  setup do
    board = insert(:board)
    works = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 2)
    %{board: board, works: works}
  end

  defp parked_run(works) do
    card = insert(:card, stage: works, status: :working)
    insert(:run, card: card, status: :parked, parked_reason: :executor_gone, current_node: nil)
  end

  defp refusal(run, reason), do: %{run_id: run.id, card_id: run.card_id, reason: reason}

  defp at(offset_s) do
    DateTime.utc_now() |> DateTime.add(offset_s, :second) |> DateTime.truncate(:second)
  end

  describe "record_resume_refusals/3" do
    test "stamps since and reason on the first refused tick", %{board: board, works: works} do
      run = parked_run(works)
      now = at(0)

      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], now)

      assert %Run{resume_refused_since: ^now, resume_refused_reason: :no_isolation} = Runs.get_run!(run.id)
    end

    test "a later tick that is still refused does not move since", %{board: board, works: works} do
      run = parked_run(works)
      first = at(-600)

      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], first)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], at(0))

      assert %Run{resume_refused_since: ^first} = Runs.get_run!(run.id)
    end

    test "a reason that changes mid-refusal updates the reason and keeps since", %{board: board, works: works} do
      run = parked_run(works)
      first = at(-600)

      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :pinned_executor_absent)], first)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_free_slot)], at(0))

      assert %Run{resume_refused_since: ^first, resume_refused_reason: :no_free_slot} = Runs.get_run!(run.id)
    end

    test "a run that stops being refused has both columns cleared", %{board: board, works: works} do
      run = parked_run(works)

      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_free_slot)], at(-600))
      :ok = Runs.record_resume_refusals(board.id, [], at(0))

      assert %Run{resume_refused_since: nil, resume_refused_reason: nil} = Runs.get_run!(run.id)
    end

    test "clearing is board-scoped: another board's refused run is left alone",
         %{board: board, works: works} do
      other_board = insert(:board)
      other_works = insert(:stage, board: other_board, name: "Code", type: :work, position: 2)
      mine = parked_run(works)
      theirs = parked_run(other_works)

      :ok = Runs.record_resume_refusals(board.id, [refusal(mine, :no_free_slot)], at(-600))
      :ok = Runs.record_resume_refusals(other_board.id, [refusal(theirs, :no_free_slot)], at(-600))

      # A quiet tick on the OTHER board must not touch this board's stamp.
      :ok = Runs.record_resume_refusals(other_board.id, [], at(0))

      assert %Run{resume_refused_since: nil, resume_refused_reason: nil} = Runs.get_run!(theirs.id)
      assert %Run{resume_refused_reason: :no_free_slot} = Runs.get_run!(mine.id)
    end

    test "resume_run/2 clears the stamp", %{board: board, works: works} do
      start_engine!()
      run = parked_run(works)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_free_slot)], at(-600))

      {:ok, _resumed} = Runs.resume_run(Runs.get_run!(run.id))

      assert %Run{resume_refused_since: nil, resume_refused_reason: nil} = Runs.get_run!(run.id)
    end
  end

  describe "abandon_unresumable_runs/1" do
    test "leaves a run refused for 29 minutes parked", %{board: board, works: works} do
      run = parked_run(works)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], at(-29 * 60))

      :ok = Runs.abandon_unresumable_runs(at(0))

      assert %Run{status: :parked} = Runs.get_run!(run.id)
    end

    test "fails a run refused for 31 minutes, naming the cause on the run and the card",
         %{board: board, works: works} do
      run = parked_run(works)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], at(-31 * 60))

      :ok = Runs.abandon_unresumable_runs(at(0))

      assert %Run{status: :failed, failure_detail: detail} = Runs.get_run!(run.id)
      assert detail =~ "resume_refused_reason=no_isolation"
      assert detail =~ "could not resume this run for 31m"

      card = Relay.Repo.get!(Schemas.Card, run.card_id)
      assert card.status == :failed

      # `list_timeline/1` merges Comment and Activity structs, so match on the struct —
      # a bare `entry.type` would KeyError on the comment `mark_failed/3` also posts.
      assert Enum.any?(Relay.Activity.list_timeline(card), fn
               %Schemas.Activity{type: :failure, text: text} ->
                 text =~ "resume_refused_reason=no_isolation"

               _entry ->
                 false
             end)
    end

    test "clears the pin when the reason proves it unhonourable", %{board: board, works: works} do
      for reason <- Run.pin_unhonourable_refusal_reasons() do
        run = parked_run(works)
        Relay.Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [pinned_executor_name: "exec-a"])
        :ok = Runs.record_resume_refusals(board.id, [refusal(run, reason)], at(-31 * 60))

        :ok = Runs.abandon_unresumable_runs(at(0))

        assert %Run{status: :failed, pinned_executor_name: nil} = Runs.get_run!(run.id)
      end
    end

    test "keeps the pin when the machine is alive and the worktree is still there",
         %{board: board, works: works} do
      for reason <- Run.resume_refusal_reasons() -- Run.pin_unhonourable_refusal_reasons() do
        run = parked_run(works)
        Relay.Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [pinned_executor_name: "exec-a"])
        :ok = Runs.record_resume_refusals(board.id, [refusal(run, reason)], at(-31 * 60))

        :ok = Runs.abandon_unresumable_runs(at(0))

        assert %Run{status: :failed, pinned_executor_name: "exec-a"} = Runs.get_run!(run.id)
      end
    end

    test "revokes a job the park left behind", %{board: board, works: works} do
      run = parked_run(works)
      execution = insert(:node_execution, run: run, node_key: "work", outcome: nil, finished_at: nil)
      job = insert(:node_job, node_execution: execution, state: :claimed)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_free_slot)], at(-31 * 60))

      :ok = Runs.abandon_unresumable_runs(at(0))

      assert Relay.Repo.get!(Schemas.NodeJob, job.id).state == :revoked
    end

    test "skips a half-written stamp instead of taking the reaper's sweep down", %{works: works} do
      run = parked_run(works)

      # `since` set, `reason` nil — reachable if a writer dies between `stamp_refusal/2`'s two
      # UPDATEs. `unresumable_detail/2` would call `Scheduler.resume_refusal_sentence(nil)`,
      # which has no catch-all clause, so a FunctionClauseError here would kill every
      # `ExecutorReaper` sweep tick until the row cleared.
      Relay.Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [resume_refused_since: at(-31 * 60), resume_refused_reason: nil]
      )

      :ok = Runs.abandon_unresumable_runs(at(0))

      assert %Run{status: :parked} = Runs.get_run!(run.id)
    end

    test "the 30-minute window is the one named policy number" do
      assert Runs.unresumable_after_s() == 1800
    end
  end

  # Mirrors test/relay/runs/exclusive_resume_test.exs' park_pinned/1: a real exclusive run,
  # claimed by exec-a, parked `:executor_gone` by the reaper when exec-a goes silent.
  defp park_pinned(board) do
    stages = Relay.Boards.list_stages(board)
    next_up = Enum.find(stages, &(&1.name == "Next up"))
    spec = Enum.find(stages, &(&1.name == "Spec"))
    plan_stage = Enum.find(stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "excl",
        isolation: :exclusive,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: plan_stage.id,
        nodes: [%{key: "work", type: :agent, run: "work {ref}"}],
        edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    {:ok, card} = Relay.Cards.create_card(next_up, %{title: "Excl card"})
    {:ok, run} = Runs.start_run(card, flow)

    {:ok, exec_a} =
      Runs.upsert_executor(board, %{"name" => "exec-a", "interval" => 30, "capacity" => %{"exclusive" => 1}})

    {:ok, _claimed} = Runs.claim_next_job(exec_a)

    Relay.Repo.update_all(from(e in Schemas.Executor, where: e.id == ^exec_a.id),
      set: [last_heartbeat: DateTime.truncate(DateTime.add(DateTime.utc_now(), -1000, :second), :second)]
    )

    :ok = Runs.reclaim_stale_executors()
    parked = Runs.get_run!(run.id)
    assert parked.status == :parked and parked.parked_reason == :executor_gone

    %{run: parked, card: card, flow: flow, exec_a: exec_a}
  end

  # One scheduler pass, recorded as of `now` — the two lines Scheduler.Server.reconcile/1 runs.
  defp refuse_once(board, now) do
    {snapshot, _cards} = Server.build_snapshot(board.id, RunsEngine)
    plan = Scheduler.plan(snapshot)
    :ok = Runs.record_resume_refusals(board.id, plan.refusals, now)
    plan
  end

  describe "end-to-end: run 368's shape (RE297)" do
    setup do
      Relay.Runs.FakeDispatcher.register(self())
      start_engine!()

      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "RE297 Board"})
      %{e2e_board: board}
    end

    test "a parked exclusive run whose flow row is gone is refused, aged out, and no longer a dead end",
         %{e2e_board: board} do
      %{run: run, flow: flow} = park_pinned(board)

      # Replacing a flow: disable, delete (the FK cascade nilifies runs.flow_id), recreate on
      # the same trigger stages. The run now reads `isolation: nil` in `active_runs/1` —
      # undispatchable forever, with no next transition to fail on. This is run 368.
      {:ok, flow} = Relay.Flows.disable_flow(flow)
      attrs = Map.take(flow, [:isolation, :pulls_from_stage_id, :works_in_stage_id, :lands_on_stage_id])
      {:ok, _deleted} = Relay.Flows.delete_flow(flow)

      {:ok, replacement} =
        Relay.Flows.create_flow(
          board,
          Map.merge(attrs, %{
            key: "excl",
            nodes: [%{key: "work", type: :agent, run: "work {ref}"}],
            edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
          })
        )

      {:ok, _replacement} = Relay.Flows.enable_flow(replacement)
      assert Runs.get_run!(run.id).flow_id == nil

      # 1. The scheduler refuses it, and says why.
      plan = refuse_once(board, at(-31 * 60))
      assert [%{run_id: refused_id, reason: :no_isolation}] = plan.refusals
      assert refused_id == run.id
      assert plan.dispatches == []

      # 2. The reaper gives up after the window.
      :ok = Runs.abandon_unresumable_runs(at(0))
      failed = Runs.get_run!(run.id)
      assert failed.status == :failed
      assert failed.failure_detail =~ "resume_refused_reason=no_isolation"

      # 3. The dead end is gone: retry is no longer refused with `not_failed` — the guard that
      # composed with the never-resuming scheduler into a state nothing could move. What it
      # refuses with now is `:no_flow`, the actionable answer the failure detail already names
      # ("move the card back to re-run it on the current flow").
      result = Runs.retry_run(failed)
      refute match?({:error, {:not_failed, _status}}, result)
      refute match?({:error, {:executor_unavailable, _name}}, result)
      assert result == {:error, :no_flow}
      assert Runs.retry_refusal_code(:no_flow) == "no_flow"
    end

    test "a parked exclusive run whose pinned executor never returns ages out and retries clean",
         %{e2e_board: board} do
      %{run: run} = park_pinned(board)

      # exec-a is `:gone`, so it advertises nothing (and `drop_gone_capacity/2` would strip any
      # lingering slot anyway): its id is not a key in the capacity map, so the pin can never
      # be satisfied — `resumable?/2` yes, `take_slot/3` :none, on every tick, forever.
      plan = refuse_once(board, at(-31 * 60))
      assert [%{run_id: _id, reason: :pinned_executor_absent}] = plan.refusals

      :ok = Runs.abandon_unresumable_runs(at(0))
      failed = Runs.get_run!(run.id)
      assert failed.status == :failed
      # The pin is provably unhonourable, so it is cleared — otherwise the hatch stays shut.
      assert failed.pinned_executor_name == nil

      assert {:ok, revived} = Runs.retry_run(failed)
      assert revived.status == :running
    end
  end
end
