defmodule Relay.Runs.Scheduler.ServerTest do
  use Relay.DataCase, async: false

  import Relay.Factory

  alias Relay.Repo
  alias Relay.Runs.Capacity
  alias Relay.Runs.Scheduler.Server
  alias Schemas.Card

  # A fake Relay.Runs.Scheduler.Engine: forwards write calls to a test pid and returns canned
  # active runs. Its collaborators live in an Agent named FakeEngine (started by
  # start_engine/1 before the server, so the server's boot reconcile can read them).
  defmodule FakeEngine do
    @moduledoc false
    @behaviour Relay.Runs.Scheduler.Engine

    @impl true
    def active_runs(_board_id), do: Agent.get(__MODULE__, & &1.runs)

    @impl true
    def start_run(card_id, flow_key, executor_id) do
      send(Agent.get(__MODULE__, & &1.test), {:start_run, card_id, flow_key, executor_id})
      :ok
    end

    @impl true
    def resume_run(run_id, executor_id) do
      send(Agent.get(__MODULE__, & &1.test), {:resume_run, run_id, executor_id})
      :ok
    end
  end

  setup do
    Capacity.reset()
    :ok
  end

  # Start the FakeEngine's collaborator Agent (named FakeEngine), seeded with the test pid and
  # the canned active runs. Must run before the server so boot reconcile sees these runs.
  defp start_engine(runs) do
    test = self()

    start_supervised!(%{
      id: FakeEngine,
      start: {Agent, :start_link, [fn -> %{test: test, runs: runs} end, [name: FakeEngine]]}
    })

    :ok
  end

  defp start_server(board_id) do
    start_supervised!(
      {Server, [board_id: board_id, engine: FakeEngine, tick_ms: 3_600_000, debounce_ms: 5, name: :"sched_#{board_id}"]}
    )
  end

  # A board with one enabled shared_clean flow: queue → work → done. Returns the pulls-from card.
  defp board_with_flow(card_status) do
    board = insert(:board)
    pulls = insert(:stage, board: board, position: 1, type: :queue)
    works = insert(:stage, board: board, position: 2, type: :work)
    lands = insert(:stage, board: board, position: 3, type: :done)

    flow =
      insert(:flow,
        board: board,
        key: "spec",
        enabled: true,
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id
      )

    card = insert(:card, stage: pulls, status: card_status)
    %{board: board, pulls: pulls, works: works, lands: lands, flow: flow, card: card}
  end

  test "zero capacity is inert and marks the eligible card :queued (criteria 3 + 5)" do
    %{board: board, card: card} = board_with_flow(:ready)
    start_engine([])
    pid = start_server(board.id)

    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 50
    assert Repo.get!(Card, card.id).status == :queued
  end

  test "capacity appearing drives a dispatch without waiting a tick (criterion 2)" do
    %{board: board, card: card} = board_with_flow(:ready)
    start_engine([])
    _pid = start_server(board.id)

    :ok = Capacity.put(7, %{shared_clean: 1, exclusive: 0})

    assert_receive {:start_run, card_id, "spec", 7}, 500
    assert card_id == card.id
  end

  test "an answered needs_input card resumes, not re-pulls (criterion 4)" do
    %{board: board, works: works} = board_with_flow(:ready)
    # a card already back in works-in as :working (just answered), with a parked run
    resumed = insert(:card, stage: works, status: :working)

    start_engine([
      %{id: 99, card_id: resumed.id, status: :parked, flow_key: "spec", isolation: :shared_clean, pinned_executor_id: nil}
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(7, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    assert_receive {:resume_run, 99, 7}, 500
    refute_receive {:start_run, _, _, _}, 50
  end

  test "an in-flight :running run holds its capacity slot across reconciles (B3 accounting)" do
    %{board: board, pulls: pulls} = board_with_flow(:ready)
    other_card = insert(:card, stage: pulls, status: :ready)

    # A running run (on some other card) already holds the board's only advertised
    # shared_clean slot — the executor's next heartbeat hasn't caught up yet.
    start_engine([
      %{id: 55, card_id: -1, status: :running, flow_key: "spec", isolation: :shared_clean, pinned_executor_id: nil}
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(7, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 50
    assert Repo.get!(Card, other_card.id).status == :queued
  end

  test "a :parked run holds no capacity slot — only :running runs are debited" do
    %{board: board, card: card} = board_with_flow(:ready)

    start_engine([
      %{id: 55, card_id: -1, status: :parked, flow_key: "spec", isolation: :shared_clean, pinned_executor_id: nil}
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(7, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    assert_receive {:start_run, card_id, "spec", 7}, 500
    assert card_id == card.id
  end

  test "a :running run whose flow was deleted (isolation: nil) leaves capacity untouched" do
    %{board: board, card: card} = board_with_flow(:ready)

    start_engine([
      %{id: 55, card_id: -1, status: :running, flow_key: "gone", isolation: nil, pinned_executor_id: nil}
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(7, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    assert_receive {:start_run, card_id, "spec", 7}, 500
    assert card_id == card.id
  end

  test "disabling the flow unqueues a previously :queued card (criterion 5)" do
    %{board: board, flow: flow, card: card} = board_with_flow(:ready)
    start_engine([])
    pid = start_server(board.id)

    :ok = Server.reconcile_now(pid)
    assert Repo.get!(Card, card.id).status == :queued

    {:ok, _} = Relay.Flows.disable_flow(flow)
    :ok = Server.reconcile_now(pid)

    assert Repo.get!(Card, card.id).status == :ready
  end
end
