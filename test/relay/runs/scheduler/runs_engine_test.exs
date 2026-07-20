defmodule Relay.Runs.Scheduler.RunsEngineTest do
  use Relay.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Relay.Runs
  alias Relay.Runs.Scheduler.RunsEngine

  setup do
    start_supervised!(Relay.Runs.Supervisor)
    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Engine Board"})
    {:ok, spec} = Relay.Flows.enable_flow(Relay.Flows.get_flow!(board, "spec"))
    next_up = Enum.find(Relay.Boards.list_stages(board), &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(next_up, %{title: "Write the spec"})
    %{board: board, card: card, flow: spec, next_up: next_up}
  end

  test "the configured production engine is the real adapter, not NoopEngine" do
    assert Application.get_env(:relay, :runs_engine) == RunsEngine
  end

  test "start_run/3 starts a run and moves the card to the works-in stage as working",
       %{card: card, flow: flow} do
    assert :ok = RunsEngine.start_run(card.id, flow.key, "exec-1")

    run = Runs.active_run(Relay.Repo.get!(Schemas.Card, card.id))
    assert run.status == :running
    moved = Relay.Repo.get!(Schemas.Card, card.id)
    assert moved.stage_id == flow.works_in_stage_id
    assert moved.status == :working
  end

  test "start_run/3 tolerates a lost race (active run already exists) as :ok",
       %{card: card, flow: flow} do
    assert :ok = RunsEngine.start_run(card.id, flow.key, "exec-1")
    # A second dispatch for the same card must not crash the scheduler — and, crucially,
    # must not create a second Run row for it.
    assert :ok = RunsEngine.start_run(card.id, flow.key, "exec-1")

    assert Relay.Repo.aggregate(from(r in Schemas.Run, where: r.card_id == ^card.id), :count) == 1
  end

  test "start_run/3 tolerates a disabled/vanished flow as :ok", %{card: card} do
    capture_log(fn ->
      assert :ok = RunsEngine.start_run(card.id, "no-such-flow", "exec-1")
    end)

    refute Runs.active_run(Relay.Repo.get!(Schemas.Card, card.id))
  end

  test "start_run/3 logs a warning on a permanent failure instead of swallowing it silently",
       %{board: board} do
    next_up = Enum.find(Relay.Boards.list_stages(board), &(&1.name == "Next up"))
    spec_stage = Enum.find(Relay.Boards.list_stages(board), &(&1.name == "Spec"))

    {:ok, human_flow} =
      Relay.Flows.create_flow(board, %{
        key: "human",
        isolation: :shared_clean,
        pulls_from_stage_id: spec_stage.id,
        works_in_stage_id: spec_stage.id,
        lands_on_stage_id: next_up.id,
        nodes: [%{key: "review", type: :human}],
        edges: [%{from: "start", to: "review"}, %{from: "review", to: "done", on: :succeeded}]
      })

    {:ok, human_flow} = Relay.Flows.enable_flow(human_flow)
    {:ok, card} = Relay.Cards.create_card(next_up, %{title: "Needs a human node"})

    log =
      capture_log(fn ->
        assert :ok = RunsEngine.start_run(card.id, human_flow.key, "exec-1")
      end)

    assert log =~ "unsupported_node_type"
    assert log =~ "card_id=#{card.id}"
    assert log =~ "flow_key=human"
  end

  test "start_run/3 logs a warning when the card, board, or flow cannot be found" do
    log =
      capture_log(fn ->
        assert :ok = RunsEngine.start_run(-1, "no-such-flow", "exec-1")
      end)

    assert log =~ "card_id=-1"
    assert log =~ "flow_key=no-such-flow"
  end

  test "active_runs/1 returns the snapshot run shape for the board's active runs",
       %{board: board, card: card, flow: flow} do
    {:ok, run} = Runs.start_run(card, flow)

    assert [got] = RunsEngine.active_runs(board.id)
    assert got.id == run.id
    assert got.card_id == card.id
    assert got.status == :running
    assert got.flow_key == "spec"
    assert got.isolation == :shared_clean
    assert got.pinned_executor_id == nil
    assert got.parked_reason == nil
  end

  test "resume_run/2 resumes a parked run and is a no-op on a non-parked run",
       %{card: card, flow: flow} do
    {:ok, run} = Runs.start_run(card, flow)
    parked = run |> Ecto.Changeset.change(status: :parked, parked_reason: :claimed) |> Relay.Repo.update!()

    assert :ok = RunsEngine.resume_run(parked.id, "exec-1")
    assert Runs.get_run!(parked.id).status == :running

    # Already running → benign no-op, no crash.
    assert :ok = RunsEngine.resume_run(parked.id, "exec-1")
  end
end
