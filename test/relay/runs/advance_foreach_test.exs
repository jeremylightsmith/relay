defmodule Relay.Runs.AdvanceForeachTest do
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.SubTask

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Advance Board"})
    start_engine!()
    %{board: board, user: user}
  end

  # A foreach flow shaped like the Code flow's implement loop: `impl` is the head, `review` is the
  # loop tail carrying the two `when` guards. The leading `seed` node exists so a run can fail
  # BEFORE the foreach node is ever entered — the only way to reach the :not_bound refusal, since
  # a foreach flow refuses to start at all without sub_tasks (failures.md B1).
  defp foreach_flow(board, opts \\ []) do
    exhausted? = Keyword.get(opts, :exhausted_edge, true)
    pulls = Enum.find(board.stages, &(&1.name == "Next up"))
    works = Enum.find(board.stages, &(&1.name == "Spec"))
    lands = Enum.find(board.stages, &(&1.name == "Plan"))

    exhausted = if exhausted?, do: [%{from: "review", to: "wrap", on: :succeeded, when: :foreach_exhausted}], else: []

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "advance-#{System.unique_integer([:positive])}",
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id,
        nodes: [
          %{key: "seed", type: :shell, run: "true"},
          %{key: "impl", type: :agent, run: "impl {ref}", expects_commits: true, foreach: "card.sub_tasks"},
          %{key: "review", type: :agent, run: "review {ref}"},
          %{key: "wrap", type: :shell, run: "true"}
        ],
        edges:
          [
            %{from: "start", to: "seed"},
            %{from: "seed", to: "impl", on: :succeeded},
            %{from: "seed", to: "needs_input", on: :failed},
            %{from: "impl", to: "review", on: :succeeded},
            %{from: "impl", to: "needs_input", on: :failed},
            %{from: "review", to: "impl", on: :failed, max_loops: 3},
            %{from: "review", to: "impl", on: :succeeded, when: :foreach_remaining},
            %{from: "wrap", to: "done", on: :succeeded}
          ] ++ exhausted
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  # A card with `count` sub_tasks and a started run, seeded past the shell node so `impl` is live
  # and bound to task 1. Sub_tasks are inserted BEFORE start_run (failures.md B1).
  defp started(board, flow, count) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "advance me"})
    tasks = for position <- 1..count//1, do: insert(:sub_task, card: card, position: position)

    {:ok, run} = Runs.start_run(card, flow)
    %{run: run, card: card, tasks: tasks}
  end

  defp past_seed(%{run: run} = state) do
    assert_receive {:dispatched, %NodeJob{node_key: "seed"} = seed}
    {:ok, _} = Runs.report_outcome(seed, %{outcome: :succeeded, detail: "ok", git_sha: "base000"})
    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = impl}
    Map.put(%{state | run: Runs.get_run!(run.id)}, :impl, impl)
  end

  # The RE306 resting state a human finds: `impl` bound to task 1, whose work is already on the
  # branch, parked for a human after the commit guard rewrote its success.
  defp stuck(board, flow, count) do
    state = past_seed(started(board, flow, count))

    {:ok, run} =
      Runs.report_outcome(state.impl, %{outcome: :failed, detail: "already committed", git_sha: "moved99"})

    %{state | run: Runs.get_run!(run.id)}
  end

  test "it checks the bound task off and re-enters bound to the NEXT one", ctx do
    flow = foreach_flow(ctx.board)
    %{run: run, tasks: [first, second]} = stuck(ctx.board, flow, 2)
    assert run.status == :parked and run.parked_reason == :needs_input

    {:ok, advanced} = Runs.advance_foreach(run)

    assert advanced.status == :running
    assert advanced.current_node == "impl"
    # A human intervention buys one more move everywhere, same as retry.
    assert advanced.retries == run.retries + 1
    assert Repo.get!(SubTask, first.id).done == true

    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = next}
    exec = Repo.get!(NodeExecution, next.node_execution_id)
    assert exec.sub_task_id == second.id
    assert exec.attempt == 1
  end

  test "it routes to the foreach_exhausted target when that was the last task", ctx do
    flow = foreach_flow(ctx.board)
    %{run: run, tasks: [only]} = stuck(ctx.board, flow, 1)

    {:ok, advanced} = Runs.advance_foreach(run)

    assert advanced.current_node == "wrap"
    assert Repo.get!(SubTask, only.id).done == true
    assert_receive {:dispatched, %NodeJob{node_key: "wrap"} = wrap}
    assert Repo.get!(NodeExecution, wrap.node_execution_id).sub_task_id == nil
  end

  test "it opens on a :question park, which retry refuses", ctx do
    # RE306's actual state was a `:question` park. Reusing retry's eligibility would leave the
    # hatch unable to open in the exact state it exists for.
    flow = foreach_flow(ctx.board)
    state = past_seed(started(ctx.board, flow, 2))
    [first, _second] = state.tasks

    {:ok, run} =
      Runs.report_outcome(state.impl, %{
        outcome: :needs_input,
        detail: "nothing to change — how do I proceed?",
        git_sha: "moved99"
      })

    run = Runs.get_run!(run.id)
    assert Runs.park_kind(run) == :question
    assert {:error, :awaiting_answer} = Runs.retry_run(run)

    assert {:ok, %{status: :running}} = Runs.advance_foreach(run)
    assert Repo.get!(SubTask, first.id).done == true
  end

  test "it refuses a running run without touching the card", ctx do
    flow = foreach_flow(ctx.board)
    %{run: run, tasks: [first | _]} = started(ctx.board, flow, 2)

    assert {:error, {:not_advanceable, "running"}} = Runs.advance_foreach(run)
    assert Repo.get!(SubTask, first.id).done == false
  end

  test "it refuses a flow with no foreach node", ctx do
    flow = foreach_flow(ctx.board)
    %{run: run, tasks: [first | _]} = stuck(ctx.board, flow, 2)
    repointed = run |> Ecto.Changeset.change(flow_id: no_foreach_flow(ctx.board).id) |> Repo.update!()

    assert {:error, :no_foreach} = Runs.advance_foreach(repointed)
    assert Repo.get!(SubTask, first.id).done == false
  end

  test "it refuses a foreach flow with no foreach_exhausted edge, writing nothing", ctx do
    # Validated up front even though tasks remain: a foreach loop with no way out cannot
    # terminate at all, and checking it here is what keeps the refusal path side-effect-free.
    flow = foreach_flow(ctx.board, exhausted_edge: false)
    %{run: run, tasks: [first | _]} = stuck(ctx.board, flow, 2)

    assert {:error, :no_exhausted_edge} = Runs.advance_foreach(run)
    assert Repo.get!(SubTask, first.id).done == false
  end

  test "it refuses a run that never reached its foreach node", ctx do
    flow = foreach_flow(ctx.board)
    %{tasks: [first | _]} = started(ctx.board, flow, 2)
    assert_receive {:dispatched, %NodeJob{node_key: "seed"} = seed}
    {:ok, run} = Runs.report_outcome(seed, %{outcome: :failed, detail: "boom"})

    assert {:error, :not_bound} = Runs.advance_foreach(Runs.get_run!(run.id))
    assert Repo.get!(SubTask, first.id).done == false
  end

  test "advance_foreach_available? answers the same question the button asks", ctx do
    flow = foreach_flow(ctx.board)
    %{run: run} = stuck(ctx.board, flow, 2)

    assert Runs.advance_foreach_available?(run)
    {:ok, advanced} = Runs.advance_foreach(run)
    refute Runs.advance_foreach_available?(advanced)
  end

  # A flow with no foreach node at all, for the :no_foreach refusal.
  defp no_foreach_flow(board) do
    pulls = Enum.find(board.stages, &(&1.name == "Next up"))
    works = Enum.find(board.stages, &(&1.name == "Spec"))
    lands = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "plain-#{System.unique_integer([:positive])}",
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id,
        nodes: [%{key: "impl", type: :agent, run: "impl {ref}"}],
        edges: [%{from: "start", to: "impl"}, %{from: "impl", to: "done", on: :succeeded}]
      })

    flow
  end
end
