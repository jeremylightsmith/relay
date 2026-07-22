defmodule Relay.Runs.RestartTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob

  setup do
    FakeDispatcher.register(self())
    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Restart Board"})
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    %{board: board, stage: stage, user: user}
  end

  # A run parked as a died-agent masquerade: :parked/:needs_input with the latest
  # NodeExecution.outcome == :failed (RLY-179). Built with factories, no engine.
  defp died_agent_park(stage) do
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Agent died"})
    run = insert(:run, card: card, status: :parked, parked_reason: :needs_input, current_node: nil)
    insert(:node_execution, run: run, node: "brainstorm", outcome: :failed)
    Runs.get_run!(run.id)
  end

  # A genuine human question: :parked/:needs_input with the latest execution :needs_input.
  defp genuine_question(stage) do
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Real question"})
    run = insert(:run, card: card, status: :parked, parked_reason: :needs_input, current_node: "brainstorm")
    insert(:node_execution, run: run, node: "brainstorm", outcome: :needs_input)
    Runs.get_run!(run.id)
  end

  defp clean_failed(stage) do
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Dead-ended"})
    run = insert(:run, card: card, status: :failed, current_node: nil, failure_detail: "boom")
    insert(:node_execution, run: run, node: "brainstorm", outcome: :failed)
    Runs.get_run!(run.id)
  end

  describe "restartable?/1 truth table" do
    test "a clean :failed run is restartable", %{stage: stage} do
      assert Runs.restartable?(clean_failed(stage))
    end

    test "a died-agent park (latest outcome :failed) is restartable", %{stage: stage} do
      assert Runs.restartable?(died_agent_park(stage))
    end

    test "a genuine :needs_input question (latest outcome :needs_input) is NOT restartable", %{stage: stage} do
      refute Runs.restartable?(genuine_question(stage))
    end

    test "an :executor_gone park is NOT restartable", %{stage: stage} do
      {:ok, card} = Relay.Cards.create_card(stage, %{title: "Executor gone"})
      run = insert(:run, card: card, status: :parked, parked_reason: :executor_gone)
      insert(:node_execution, run: run, node: "brainstorm", outcome: :failed)
      refute Runs.restartable?(Runs.get_run!(run.id))
    end

    test "running/done/cancelled are NOT restartable", %{stage: stage} do
      for status <- [:running, :done, :cancelled] do
        {:ok, card} = Relay.Cards.create_card(stage, %{title: "S #{status}"})
        run = insert(:run, card: card, status: status)
        refute Runs.restartable?(Runs.get_run!(run.id)), "expected #{status} not restartable"
      end
    end
  end

  describe "restart_stalled/2 + restartable_count/1" do
    # A flow whose failed edge parks the run on needs_input (the RLY-194 shape), so a
    # reported :failed produces a real died-agent park the sweep can revive in place.
    defp park_flow(board) do
      next_up = Enum.find(board.stages, &(&1.name == "Next up"))
      spec = Enum.find(board.stages, &(&1.name == "Spec"))
      review = Enum.find(board.stages, &(&1.name == "Spec:Review"))

      {:ok, flow} =
        Relay.Flows.create_flow(board, %{
          key: "park-flow",
          isolation: :shared_clean,
          pulls_from_stage_id: next_up.id,
          works_in_stage_id: spec.id,
          lands_on_stage_id: review.id,
          nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}"}],
          edges: [
            %{from: "start", to: "brainstorm"},
            %{from: "brainstorm", to: "done", on: :succeeded},
            %{from: "brainstorm", to: "needs_input", on: :failed}
          ]
        })

      {:ok, flow} = Relay.Flows.enable_flow(flow)
      flow
    end

    defp park_a_run(card, flow, outcome, detail) do
      {:ok, _run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, %NodeJob{} = job}
      {:ok, run} = Runs.report_outcome(job, %{outcome: outcome, detail: detail, session_id: "s"})
      run
    end

    setup %{board: board} do
      start_supervised!(Relay.Runs.Supervisor)
      %{flow: park_flow(board)}
    end

    test "it revives every restartable run and skips a genuine question", ctx do
      stage = Enum.find(ctx.board.stages, &(&1.name == "Next up"))
      {:ok, died_card} = Relay.Cards.create_card(stage, %{title: "Died"})
      {:ok, ask_card} = Relay.Cards.create_card(stage, %{title: "Asked"})

      died = park_a_run(died_card, ctx.flow, :failed, "spend limit")
      ask = park_a_run(ask_card, ctx.flow, :needs_input, "Which auth model?")
      assert Runs.get_run!(died.id).status == :parked
      assert Runs.get_run!(ask.id).status == :parked

      assert Runs.restartable_count(ctx.board) == 1

      summary = Runs.restart_stalled(ctx.board, :agent)

      assert summary.restarted == 1
      assert Runs.get_run!(died.id).status == :running
      assert Runs.get_run!(ask.id).status == :parked
      assert Runs.get_run!(ask.id).parked_reason == :needs_input
      assert Runs.restartable_count(ctx.board) == 0
    end
  end

  describe "check_retryable via retry_run/2 refusal" do
    test "a genuine question refuses with :awaiting_answer, not revived", %{stage: stage} do
      run = genuine_question(stage)
      assert {:error, reason} = Runs.retry_run(run)
      assert Runs.retry_refusal_code(reason) == "awaiting_answer"
      assert Runs.retry_refusal_message(reason) =~ "waiting on a human answer"
      assert Runs.get_run!(run.id).status == :parked
    end
  end
end
