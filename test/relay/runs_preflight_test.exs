defmodule Relay.RunsPreflightTest do
  @moduledoc """
  The candidate matrix for `Runs.preflight_flow/1` (RLY-182).

  The two cases that carry the design: (a) two runners each satisfying half must NOT read
  as ready — a run dispatches to ONE machine, so a union would lie; (b) a runner that has
  never reported its inventory must NOT be listed as missing anything.
  """
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Runs
  alias Relay.Runs.Capacity
  # The Plan flow's trigger (`Relay.Flows.DefaultLibrary`) is "Spec:Done" -> "Plan" ->
  # "Plan:Done" — the sub-lanes only exist once enabled, same setup as flows_seed_test.exs.
  alias Relay.Runs.Preflight

  setup do
    start_engine!()
    board = insert(:board)
    spec = insert(:stage, board: board, name: "Spec", category: :planning, type: :planning, position: 1)
    plan_stage = insert(:stage, board: board, name: "Plan", category: :planning, type: :planning, position: 2)
    {:ok, _spec_done} = Boards.enable_lane(spec, :done)
    {:ok, _plan_done} = Boards.enable_lane(plan_stage, :done)
    :ok = Flows.seed_default_flows!(board)
    %{board: board, flow: Flows.get_flow!(board, "plan")}
  end

  defp connect(board, opts) do
    runner = insert(:runner, board: board, name: opts[:name] || "mac-1", capabilities: opts[:capabilities])

    runner =
      case opts[:last_heartbeat] do
        nil -> runner
        at -> runner |> Ecto.Changeset.change(last_heartbeat: at) |> Relay.Repo.update!()
      end

    Capacity.put(runner.id, runner.board_id, opts[:capacity] || %{shared_clean: 1, exclusive: 1})
    runner
  end

  defp full, do: %{"agents" => [], "skills" => ["write-plan"]}

  test "the Plan flow requires the write-plan skill and no agents", %{flow: flow} do
    assert Runs.preflight_flow(flow).requires == %{agents: [], skills: ["write-plan"]}
  end

  test "no runners at all", %{flow: flow} do
    result = Runs.preflight_flow(flow)
    assert result.runners == :none_connected
    refute result.ready?
  end

  test "a fresh runner with capacity and everything resolved is ready", %{board: board, flow: flow} do
    connect(board, capabilities: full())
    result = Runs.preflight_flow(flow)

    assert result.runners == {:ok, "mac-1"}
    assert result.stages == :ok
    assert result.unreported == []
    assert result.ready?
  end

  test "zero capacity in the flow's own isolation class disqualifies", %{board: board, flow: flow} do
    connect(board, capabilities: full(), capacity: %{shared_clean: 0, exclusive: 4})
    result = Runs.preflight_flow(flow)

    assert {:no_candidate, [detail]} = result.runners
    refute detail.capacity_ok?
    refute result.ready?
  end

  test "a missing skill is named, and disqualifies", %{board: board, flow: flow} do
    connect(board, capabilities: %{"agents" => [], "skills" => ["brainstorm"]})
    result = Runs.preflight_flow(flow)

    assert {:no_candidate, [detail]} = result.runners
    assert detail.missing_skills == ["write-plan"]
    refute result.ready?
  end

  test "a stale runner is not a candidate however complete it is", %{board: board, flow: flow} do
    # Between fresh (<=45s at the default 30s interval) and gone (>60s, `runner_stale?/2`'s
    # own floor) — a beat that's late but not yet reaped.
    stale_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-50, :second)
    connect(board, capabilities: full(), last_heartbeat: stale_at)
    result = Runs.preflight_flow(flow)

    assert {:no_candidate, [detail]} = result.runners
    assert detail.freshness == :stale
    refute result.ready?
  end

  test "a gone runner is not connected at all", %{board: board, flow: flow} do
    # Past `runner_stale?/2`'s floor — the reaper has already requeued/parked its work, so
    # it must not be counted as connected, nor union its stale inventory into "missing".
    gone_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600, :second)
    connect(board, capabilities: full(), last_heartbeat: gone_at)
    result = Runs.preflight_flow(flow)

    assert result.runners == :none_connected
    assert result.unreported == []
    refute result.ready?
  end

  test "a runner that never reported is not listed as missing anything", %{board: board, flow: flow} do
    connect(board, capabilities: nil)
    result = Runs.preflight_flow(flow)

    assert result.unreported == ["mac-1"]
    assert {:ok, "mac-1"} = result.runners
  end

  test "two runners each satisfying half is not ready", %{board: board, flow: flow} do
    connect(board, name: "has-files", capabilities: full(), capacity: %{shared_clean: 0, exclusive: 0})
    connect(board, name: "has-slots", capabilities: %{"agents" => [], "skills" => []})

    result = Runs.preflight_flow(flow)

    assert {:no_candidate, details} = result.runners
    assert Enum.map(details, & &1.name) == ["has-files", "has-slots"]
    refute result.ready?
  end

  test "23. a flow on the board's first main stage has nowhere to pull from (RE429, RE430)", %{board: board} do
    spec_flow = Flows.get_flow!(board, "spec")
    connect(board, capabilities: %{"agents" => [], "skills" => ["brainstorm"]})

    result = Preflight.run(spec_flow)
    assert {:problem, %{kind: :no_upstream, flow_key: "spec"}} = result.stages
    refute result.ready?

    {:ok, default_board} = Boards.create_board(insert(:user), %{name: "Preflight"})
    deploy = Relay.Repo.get_by!(Schemas.Stage, board_id: default_board.id, name: "Deploy")

    {:ok, ship} =
      Flows.create_flow(default_board, %{
        key: "ship",
        isolation: :shared_clean,
        stage_id: deploy.id,
        nodes: [],
        edges: [%{from: "start", to: "done"}]
      })

    # RE430: the default board puts the Review main stage right before Deploy, so `ship` starts
    # on a broken shape; its first fix (Review · Done) makes it healthy.
    assert {:problem, %{kind: :upstream_review, flow_key: "ship"}} = Preflight.run(ship).stages

    review = Relay.Repo.get_by!(Schemas.Stage, board_id: default_board.id, name: "Review")
    {:ok, _} = Boards.enable_lane(review, :done)

    assert Preflight.run(ship).stages == :ok
  end
end
