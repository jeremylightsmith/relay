defmodule Hamaca.Runs.ExclusiveResumeTest do
  use Hamaca.DataCase, async: true

  import Ecto.Query

  alias Hamaca.Runs
  alias Hamaca.Runs.Capacity
  alias Hamaca.Runs.Scheduler
  alias Hamaca.Runs.Scheduler.RunsEngine
  alias Hamaca.Runs.Scheduler.Server
  alias Schemas.Runner

  setup do
    Hamaca.Runs.FakeDispatcher.register(self())
    start_engine!()

    user = insert(:user)
    {:ok, board} = Hamaca.Boards.create_board(user, %{name: "Excl Board"})
    %{board: board}
  end

  defp exclusive_flow(board) do
    spec = Enum.find(Hamaca.Boards.list_stages(board), &(&1.name == "Spec"))

    :ok = clear_spec_flow!(board)

    {:ok, flow} =
      Hamaca.Flows.create_flow(board, %{
        key: "excl",
        isolation: :exclusive,
        stage_id: spec.id,
        nodes: [%{key: "work", type: :agent, run: "work {ref}"}],
        edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Hamaca.Flows.enable_flow(flow)
    flow
  end

  # Park an exclusive run via the reaper, pinned to exec-a.
  defp park_pinned(board) do
    flow = exclusive_flow(board)

    {:ok, card} =
      Hamaca.Cards.create_card(Enum.find(Hamaca.Boards.list_stages(board), &(&1.name == "Next up")), %{title: "Excl card"})

    {:ok, run} = Runs.start_run(card, flow)

    {:ok, exec_a} =
      Runs.upsert_runner(board, %{"name" => "exec-a", "interval" => 30, "capacity" => %{"exclusive" => 1}})

    {:ok, _claimed} = Runs.claim_next_job(exec_a)

    # Backdate exec-a past 2 × interval so the reaper reads it stale, with an injected clock.
    Hamaca.Repo.update_all(from(e in Runner, where: e.id == ^exec_a.id),
      set: [last_heartbeat: DateTime.truncate(DateTime.add(DateTime.utc_now(), -1000, :second), :second)]
    )

    :ok = Runs.reclaim_stale_runners()

    parked = Runs.get_run!(run.id)
    assert parked.status == :parked
    assert parked.parked_reason == :runner_gone
    assert parked.pinned_runner_name == "exec-a"

    %{run: parked, exec_a: exec_a}
  end

  test "a reaper-parked exclusive run resumes on the same runner when it returns", %{board: board} do
    %{run: run} = park_pinned(board)

    # exec-a genuinely returns: a fresh heartbeat refreshes last_heartbeat AND re-advertises
    # its free exclusive slot — mirroring the heartbeat endpoint (upsert_runner + Capacity.put).
    {:ok, exec_a} =
      Runs.upsert_runner(board, %{"name" => "exec-a", "interval" => 30, "capacity" => %{"exclusive" => 1}})

    :ok = Capacity.put(exec_a.id, exec_a.board_id, %{shared_clean: 0, exclusive: 1})

    {snapshot, _cards} = Server.build_snapshot(board.id, RunsEngine)
    plan = Scheduler.plan(snapshot)

    assert plan.dispatches == [{:resume, run.id, exec_a.id}]
  end

  test "a gone runner's lingering capacity does not resume the pinned run (no oscillation)", %{board: board} do
    %{exec_a: exec_a} = park_pinned(board)

    # exec-a is gone — its stale heartbeat is why the reaper parked the run — but its
    # last-advertised exclusive slot still lingers in the capacity table (nothing cleared it).
    # The planner must NOT resume onto a machine the reaper has already given up on, or the run
    # oscillates forever: resume → reap → resume (RLY-199).
    :ok = Capacity.put(exec_a.id, exec_a.board_id, %{shared_clean: 0, exclusive: 1})

    {snapshot, _cards} = Server.build_snapshot(board.id, RunsEngine)
    plan = Scheduler.plan(snapshot)

    assert plan.dispatches == []
  end

  test "a different runner with free exclusive capacity cannot take over the pinned run", %{board: board} do
    %{run: _run} = park_pinned(board)

    # A DIFFERENT runner (exec-b) advertises exclusive capacity; exec-a stays absent.
    {:ok, exec_b} = Runs.upsert_runner(board, %{"name" => "exec-b", "capacity" => %{"exclusive" => 1}})
    :ok = Capacity.put(exec_b.id, exec_b.board_id, %{shared_clean: 0, exclusive: 1})

    {snapshot, _cards} = Server.build_snapshot(board.id, RunsEngine)
    plan = Scheduler.plan(snapshot)

    # The pin is absolute: no resume is planned onto exec-b.
    assert plan.dispatches == []
  end

  test "relay why names the refusal and the awaited machine while the gone runner's capacity lingers",
       %{board: board} do
    %{run: run, exec_a: exec_a} = park_pinned(board)

    # The live-server symptom of the oscillation: exec-a is gone but its advertised slot still
    # lingers, so `explain/2` used to see a planned resume and report "dispatchable", never
    # naming exec-a. With the gone runner's capacity dropped, diagnose reaches run_verdict
    # and names the machine the run waits for (criterion 3).
    :ok = Capacity.put(exec_a.id, exec_a.board_id, %{shared_clean: 0, exclusive: 1})

    card = Hamaca.Cards.get_card(board, run.card_id)

    assert %{verdict: :resume_refused, detail: detail, evidence: evidence} = Runs.diagnose(board, card)
    assert detail =~ ~s(runner "exec-a")
    assert evidence.pinned_runner_name == "exec-a"
    assert evidence.resume_refused_reason == :pinned_runner_absent
  end

  # A stage holds exactly one flow: take the board's seeded "spec" flow off Spec so a test
  # flow can work there (it then pulls from "Next up" and lands on Spec:Review, by board order).
  defp clear_spec_flow!(board) do
    if spec = Hamaca.Flows.get_flow(board, "spec") do
      {:ok, spec} = Hamaca.Flows.disable_flow(spec)
      {:ok, _} = Hamaca.Flows.delete_flow(spec)
    end

    :ok
  end
end
