defmodule RelayWeb.Api.PlanFlowE2ETest do
  @moduledoc """
  RLY-138 / W12 — the Plan cutover, proved end to end over the real REST API with no `claude`
  invocation: a card in *Spec:Done* is dispatched by the server-side scheduler, claimed by a
  scripted executor over `POST /api/node-jobs/claim`, reported `succeeded` over
  `POST /api/node-jobs/:id/outcome`, and lands on *Plan:Done*.

  The second case is the real point of the card: **Spec and Plan enabled at once**, competing
  for one advertised `shared_clean` budget, both completing without interference. That is the
  test that would catch a Spec-specific assumption baked into W5-W8.

  Uses `Relay.Runs.Scheduler.ScriptedExecutor` (W11's harness, `test/support/scripted_executor.ex`)
  for the claim/outcome HTTP calls rather than re-implementing them here.
  """
  use RelayWeb.ConnCase, async: false

  alias Relay.Cards
  alias Relay.Flows
  alias Relay.Repo
  alias Relay.Runs
  alias Relay.Runs.Capacity
  alias Relay.Runs.Scheduler.ScriptedExecutor, as: Exec
  alias Relay.Runs.Scheduler.Server

  @executor_name "e2e-executor"
  @default_capacity %{"shared_clean" => 1, "exclusive" => 0}

  setup %{conn: conn} do
    Capacity.reset()
    start_supervised!(Relay.Runs.Supervisor)

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Cutover Board"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)

    conn = put_req_header(conn, "authorization", "Bearer " <> token)

    %{conn: conn, board: board}
  end

  defp stage(board, name), do: Enum.find(board.stages, &(&1.name == name))

  defp enable(board, key) do
    {:ok, flow} = board |> Flows.get_flow!(key) |> Flows.enable_flow()
    flow
  end

  defp card_in(board, stage_name, attrs) do
    {:ok, card} = Cards.create_card(stage(board, stage_name), Map.take(attrs, [:title]))
    {:ok, card} = Cards.update_card(card, Map.delete(attrs, :title))
    card
  end

  # Delegates the HTTP claim to ScriptedExecutor (W11's harness) — returns the decoded
  # payload map, or nil on 204 (nothing claimable).
  defp claim(conn, capacity \\ @default_capacity), do: Exec.claim(conn, @executor_name, capacity)

  # Delegates the HTTP outcome report to ScriptedExecutor.
  defp report(conn, job_id, outcome), do: Exec.outcome(conn, job_id, %{"outcome" => outcome, "detail" => "ok"})

  # Announce the executor over HTTP (a 204 claim doubles as the heartbeat that upserts it),
  # then publish its free slots so the scheduler can name it in a dispatch.
  defp announce(conn, board, slots) do
    capacity = %{"shared_clean" => slots.shared_clean, "exclusive" => slots.exclusive}
    assert claim(conn, capacity) == nil
    executor = Repo.get_by!(Schemas.Executor, board_id: board.id, name: @executor_name)
    :ok = Capacity.put(executor.id, slots)
    executor
  end

  defp start_scheduler(board) do
    start_supervised!({Server, [board_id: board.id, tick_ms: 3_600_000, debounce_ms: 5, name: :"e2e_sched_#{board.id}"]})
  end

  defp stage_name(board, card_id) do
    card = Cards.get_card(board, card_id)
    Enum.find(board.stages, &(&1.id == card.stage_id)).name
  end

  describe "the Plan flow, end to end" do
    test "a card in Spec:Done is dispatched, claimed, reported, and lands on Plan:Done",
         %{conn: conn, board: board} do
      enable(board, "plan")
      card = card_in(board, "Spec:Done", %{title: "Has a spec", spec: "# An approved spec\n\nDo the thing."})
      ref = Cards.ref(board, card)

      announce(conn, board, %{shared_clean: 1, exclusive: 0})
      server = start_scheduler(board)
      :ok = Server.reconcile_now(server)

      # The scheduler started a real run via Relay.Runs.Scheduler.RunsEngine.
      assert [run] = Runs.active_runs(board.id)
      assert run.card_id == card.id
      assert run.flow_key == "plan"
      # start_run moved the card into the flow's works_in stage.
      assert stage_name(board, card.id) == "Plan"

      # The executor claims the node-job. The payload carries the RAW, unexpanded run string —
      # template expansion is the executor's job, not the server's.
      body = claim(conn)
      assert body["run_id"] == run.id
      assert body["node_id"] == "write_plan"
      assert body["node_type"] == "agent"
      assert body["isolation"] == "shared_clean"
      assert body["run"] == "/write-plan {ref}"
      assert body["vars"]["ref"] == ref

      assert report(conn, body["id"], "succeeded") == %{"status" => "ok", "run_state" => "done"}

      assert Runs.get_run!(run.id).status == :done
      assert stage_name(board, card.id) == "Plan:Done"
    end

    test "a needs_input outcome parks the run and blocks the card instead of landing it",
         %{conn: conn, board: board} do
      # The plan flow has only `write_plan -> done on: :succeeded`; the engine parks on
      # needs_input WITHOUT an edge, which is what lets /write-plan raise needs-input on a
      # card with no approved spec rather than silently landing an empty plan.
      enable(board, "plan")
      card = card_in(board, "Spec:Done", %{title: "No spec at all"})

      announce(conn, board, %{shared_clean: 1, exclusive: 0})
      server = start_scheduler(board)
      :ok = Server.reconcile_now(server)

      assert [run] = Runs.active_runs(board.id)
      body = claim(conn)

      assert Exec.outcome(conn, body["id"], %{"outcome" => "needs_input", "detail" => "no approved spec"}) ==
               %{"status" => "ok", "run_state" => "parked"}

      assert Runs.get_run!(run.id).status == :parked
      assert Cards.get_card(board, card.id).status == :needs_input
      refute stage_name(board, card.id) == "Plan:Done"
    end
  end

  describe "Spec and Plan enabled at once" do
    test "both flows complete through one scheduler and one advertised budget",
         %{conn: conn, board: board} do
      enable(board, "spec")
      enable(board, "plan")

      spec_card = card_in(board, "Next up", %{title: "Needs a spec"})
      plan_card = card_in(board, "Spec:Done", %{title: "Needs a plan", spec: "# Approved"})

      announce(conn, board, %{shared_clean: 2, exclusive: 0})
      server = start_scheduler(board)
      :ok = Server.reconcile_now(server)

      assert length(Runs.active_runs(board.id)) == 2

      # Claim and complete both jobs, keying each by its node so claim order is irrelevant.
      capacity = %{"shared_clean" => 2, "exclusive" => 0}

      payloads =
        for _ <- 1..2 do
          body = claim(conn, capacity)
          assert report(conn, body["id"], "succeeded") == %{"status" => "ok", "run_state" => "done"}
          body
        end

      by_node = Map.new(payloads, &{&1["node_id"], &1})

      assert by_node["brainstorm"]["run"] == "/brainstorm {ref}"
      assert by_node["brainstorm"]["vars"]["ref"] == Cards.ref(board, spec_card)
      assert by_node["write_plan"]["run"] == "/write-plan {ref}"
      assert by_node["write_plan"]["vars"]["ref"] == Cards.ref(board, plan_card)

      # No interference: each card walked its own flow to its own lands_on stage.
      assert stage_name(board, spec_card.id) == "Spec:Review"
      assert stage_name(board, plan_card.id) == "Plan:Done"
      assert Runs.active_runs(board.id) == []
    end

    test "with only one shared slot, the Plan card is worked and the Spec card waits",
         %{conn: conn, board: board} do
      # The live counterpart of Task 2's pure-scheduler case: rightmost-works_in-first means
      # Plan preempts Spec for the single shared_clean slot.
      enable(board, "spec")
      enable(board, "plan")

      spec_card = card_in(board, "Next up", %{title: "Waits its turn"})
      plan_card = card_in(board, "Spec:Done", %{title: "Goes first", spec: "# Approved"})

      announce(conn, board, %{shared_clean: 1, exclusive: 0})
      server = start_scheduler(board)
      :ok = Server.reconcile_now(server)

      assert [run] = Runs.active_runs(board.id)
      assert run.card_id == plan_card.id
      assert run.flow_key == "plan"
      assert stage_name(board, spec_card.id) == "Next up"
    end
  end
end
