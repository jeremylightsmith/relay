defmodule Relay.Runs.ExclusiveResumeTest do
  use Relay.DataCase, async: false

  import Ecto.Query

  alias Relay.Runs
  alias Relay.Runs.Capacity
  alias Relay.Runs.Scheduler
  alias Relay.Runs.Scheduler.RunsEngine
  alias Relay.Runs.Scheduler.Server
  alias Schemas.Executor

  setup do
    Relay.Runs.FakeDispatcher.register(self())
    start_supervised!(Relay.Runs.Supervisor)
    Capacity.reset()

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Excl Board"})
    %{board: board}
  end

  defp exclusive_flow(board) do
    next_up = Enum.find(Relay.Boards.list_stages(board), &(&1.name == "Next up"))
    spec = Enum.find(Relay.Boards.list_stages(board), &(&1.name == "Spec"))
    plan = Enum.find(Relay.Boards.list_stages(board), &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "excl",
        isolation: :exclusive,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: plan.id,
        nodes: [%{key: "work", type: :agent, run: "work {ref}"}],
        edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  # Park an exclusive run via the reaper, pinned to exec-a.
  defp park_pinned(board) do
    flow = exclusive_flow(board)

    {:ok, card} =
      Relay.Cards.create_card(Enum.find(Relay.Boards.list_stages(board), &(&1.name == "Next up")), %{title: "Excl card"})

    {:ok, run} = Runs.start_run(card, flow)

    {:ok, exec_a} =
      Runs.upsert_executor(board, %{"name" => "exec-a", "interval" => 30, "capacity" => %{"exclusive" => 1}})

    {:ok, _claimed} = Runs.claim_next_job(exec_a)

    # Backdate exec-a past 2 × interval so the reaper reads it stale, with an injected clock.
    Relay.Repo.update_all(from(e in Executor, where: e.id == ^exec_a.id),
      set: [last_heartbeat: DateTime.truncate(DateTime.add(DateTime.utc_now(), -1000, :second), :second)]
    )

    :ok = Runs.reclaim_stale_executors()

    parked = Runs.get_run!(run.id)
    assert parked.status == :parked
    assert parked.parked_reason == :executor_gone
    assert parked.pinned_executor_name == "exec-a"

    %{run: parked, exec_a: exec_a}
  end

  test "a reaper-parked exclusive run resumes on the same executor when it returns", %{board: board} do
    %{run: run, exec_a: exec_a} = park_pinned(board)

    # exec-a returns: re-advertise a free exclusive slot keyed by its row id.
    :ok = Capacity.put(exec_a.id, %{shared_clean: 0, exclusive: 1})

    {snapshot, _cards} = Server.build_snapshot(board.id, RunsEngine)
    plan = Scheduler.plan(snapshot)

    assert plan.dispatches == [{:resume, run.id, exec_a.id}]
  end

  test "a different executor with free exclusive capacity cannot take over the pinned run", %{board: board} do
    %{run: _run} = park_pinned(board)

    # A DIFFERENT executor (exec-b) advertises exclusive capacity; exec-a stays absent.
    {:ok, exec_b} = Runs.upsert_executor(board, %{"name" => "exec-b", "capacity" => %{"exclusive" => 1}})
    :ok = Capacity.put(exec_b.id, %{shared_clean: 0, exclusive: 1})

    {snapshot, _cards} = Server.build_snapshot(board.id, RunsEngine)
    plan = Scheduler.plan(snapshot)

    # The pin is absolute: no resume is planned onto exec-b.
    assert plan.dispatches == []
  end
end
