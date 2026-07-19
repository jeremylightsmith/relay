defmodule Relay.RunsPreflightTest do
  @moduledoc """
  The candidate matrix for `Runs.preflight_flow/1` (RLY-182).

  The two cases that carry the design: (a) two executors each satisfying half must NOT read
  as ready — a run dispatches to ONE machine, so a union would lie; (b) an executor that has
  never reported its inventory must NOT be listed as missing anything.
  """
  use Relay.DataCase, async: false

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Runs
  alias Relay.Runs.Capacity

  # The Plan flow's trigger (`Relay.Flows.DefaultLibrary`) is "Spec:Done" -> "Plan" ->
  # "Plan:Done" — the sub-lanes only exist once enabled, same setup as flows_seed_test.exs.
  setup do
    start_supervised!(Relay.Runs.Supervisor)
    board = insert(:board)
    spec = insert(:stage, board: board, name: "Spec", category: :planning, type: :planning, position: 1)
    plan_stage = insert(:stage, board: board, name: "Plan", category: :planning, type: :planning, position: 2)
    {:ok, _spec_done} = Boards.enable_lane(spec, :done)
    {:ok, _plan_done} = Boards.enable_lane(plan_stage, :done)
    :ok = Flows.seed_default_flows!(board)
    %{board: board, flow: Flows.get_flow!(board, "plan")}
  end

  defp connect(board, opts) do
    executor = insert(:executor, board: board, name: opts[:name] || "mac-1", capabilities: opts[:capabilities])

    executor =
      case opts[:last_heartbeat] do
        nil -> executor
        at -> executor |> Ecto.Changeset.change(last_heartbeat: at) |> Relay.Repo.update!()
      end

    Capacity.put(executor.id, opts[:capacity] || %{shared_clean: 1, exclusive: 1})
    executor
  end

  defp full, do: %{"agents" => [], "skills" => ["write-plan"]}

  test "the Plan flow requires the write-plan skill and no agents", %{flow: flow} do
    assert Runs.preflight_flow(flow).requires == %{agents: [], skills: ["write-plan"]}
  end

  test "no executors at all", %{flow: flow} do
    result = Runs.preflight_flow(flow)
    assert result.executors == :none_connected
    refute result.ready?
  end

  test "a fresh executor with capacity and everything resolved is ready", %{board: board, flow: flow} do
    connect(board, capabilities: full())
    result = Runs.preflight_flow(flow)

    assert result.executors == {:ok, "mac-1"}
    assert result.stages == :ok
    assert result.unreported == []
    assert result.ready?
  end

  test "zero capacity in the flow's own isolation class disqualifies", %{board: board, flow: flow} do
    connect(board, capabilities: full(), capacity: %{shared_clean: 0, exclusive: 4})
    result = Runs.preflight_flow(flow)

    assert {:no_candidate, [detail]} = result.executors
    refute detail.capacity_ok?
    refute result.ready?
  end

  test "a missing skill is named, and disqualifies", %{board: board, flow: flow} do
    connect(board, capabilities: %{"agents" => [], "skills" => ["brainstorm"]})
    result = Runs.preflight_flow(flow)

    assert {:no_candidate, [detail]} = result.executors
    assert detail.missing_skills == ["write-plan"]
    refute result.ready?
  end

  test "a stale executor is not a candidate however complete it is", %{board: board, flow: flow} do
    # Between fresh (<=45s at the default 30s interval) and gone (>60s, `executor_stale?/2`'s
    # own floor) — a beat that's late but not yet reaped.
    stale_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-50, :second)
    connect(board, capabilities: full(), last_heartbeat: stale_at)
    result = Runs.preflight_flow(flow)

    assert {:no_candidate, [detail]} = result.executors
    assert detail.freshness == :stale
    refute result.ready?
  end

  test "a gone executor is not connected at all", %{board: board, flow: flow} do
    # Past `executor_stale?/2`'s floor — the reaper has already requeued/parked its work, so
    # it must not be counted as connected, nor union its stale inventory into "missing".
    gone_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600, :second)
    connect(board, capabilities: full(), last_heartbeat: gone_at)
    result = Runs.preflight_flow(flow)

    assert result.executors == :none_connected
    assert result.unreported == []
    refute result.ready?
  end

  test "an executor that never reported is not listed as missing anything", %{board: board, flow: flow} do
    connect(board, capabilities: nil)
    result = Runs.preflight_flow(flow)

    assert result.unreported == ["mac-1"]
    assert {:ok, "mac-1"} = result.executors
  end

  test "two executors each satisfying half is not ready", %{board: board, flow: flow} do
    connect(board, name: "has-files", capabilities: full(), capacity: %{shared_clean: 0, exclusive: 0})
    connect(board, name: "has-slots", capabilities: %{"agents" => [], "skills" => []})

    result = Runs.preflight_flow(flow)

    assert {:no_candidate, details} = result.executors
    assert Enum.map(details, & &1.name) == ["has-files", "has-slots"]
    refute result.ready?
  end

  test "a nilified trigger stage is reported as missing", %{board: board, flow: flow} do
    {:ok, flow} = flow |> Ecto.Changeset.change(lands_on_stage_id: nil) |> Relay.Repo.update()
    connect(board, capabilities: full())

    result = Runs.preflight_flow(flow)
    assert result.stages == {:missing, [:lands_on]}
    refute result.ready?
  end
end
