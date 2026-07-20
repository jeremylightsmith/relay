defmodule Relay.Runs.RetryTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Retry Board"})
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Do not throw my work away"})
    start_supervised!(Relay.Runs.Supervisor)
    %{board: board, flow: flow, card: card, user: user}
  end

  # `brainstorm` has max_retries: 1 and no :failed edge, so two failures end the run.
  defp failed_run(card, flow) do
    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = first}
    {:ok, _run} = Runs.report_outcome(first, %{outcome: :failed, detail: "first boom"})
    assert_receive {:dispatched, %NodeJob{} = second}
    {:ok, run} = Runs.report_outcome(second, %{outcome: :failed, detail: "final boom"})
    assert run.status == :failed
    Runs.get_run!(run.id)
  end

  test "it revives the run at the node that died, recovering the nilled current_node", ctx do
    run = failed_run(ctx.card, ctx.flow)
    assert run.current_node == nil

    {:ok, revived} = Runs.retry_run(run)

    assert revived.status == :running
    assert revived.current_node == "brainstorm"
    assert revived.failure_detail == nil
    assert revived.finished_at == nil
    assert revived.retries == 1

    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"}}
  end

  test "the re-entered job is the failed node, never the flow's start node", ctx do
    run = failed_run(ctx.card, ctx.flow)
    {:ok, _revived} = Runs.retry_run(run)

    assert_receive {:dispatched, %NodeJob{node_key: node_key, payload: payload}}
    assert node_key == "brainstorm"
    assert payload["vars"]["findings"] == "final boom"
  end

  test "it puts the card back to :working", ctx do
    run = failed_run(ctx.card, ctx.flow)
    assert Repo.get!(Schemas.Card, ctx.card.id).status == :failed

    {:ok, _revived} = Runs.retry_run(run)
    assert Repo.get!(Schemas.Card, ctx.card.id).status == :working
  end

  test "--at targets a fresh visit of the named node", ctx do
    run = failed_run(ctx.card, ctx.flow)
    {:ok, revived} = Runs.retry_run(run, at: "brainstorm")

    assert revived.current_node == "brainstorm"
    assert_receive {:dispatched, %NodeJob{node_execution_id: id}}
    execution = Repo.get!(NodeExecution, id)
    assert execution.visit == 2
    assert execution.attempt == 1
  end

  test "--at an unknown node is refused, queues nothing, and leaves the run failed", ctx do
    run = failed_run(ctx.card, ctx.flow)

    assert {:error, {:unknown_node, "not_a_node"} = reason} = Runs.retry_run(run, at: "not_a_node")
    assert Runs.retry_refusal_code(reason) == "unknown_node"
    assert Runs.retry_refusal_message(reason) =~ "not_a_node"
    assert Runs.get_run!(run.id).status == :failed
    refute_receive {:dispatched, _job}, 100
  end

  test "the edge sentinels start and done are refused like any unknown node", ctx do
    run = failed_run(ctx.card, ctx.flow)
    assert {:error, {:unknown_node, "start"}} = Runs.retry_run(run, at: "start")
    assert {:error, {:unknown_node, "done"}} = Runs.retry_run(run, at: "done")
  end

  test "the failed node was removed from the flow since: refused, queues nothing, run stays failed", ctx do
    run = failed_run(ctx.card, ctx.flow)

    flow = Relay.Flows.get_flow!(ctx.board, "spec")
    kept_nodes = Enum.reject(flow.nodes, &(&1.key == "brainstorm"))
    flow |> Ecto.Changeset.change() |> Ecto.Changeset.put_embed(:nodes, kept_nodes) |> Repo.update!()

    assert {:error, {:unknown_node, "brainstorm"} = reason} = Runs.retry_run(run)
    assert Runs.retry_refusal_code(reason) == "unknown_node"
    assert Runs.retry_refusal_message(reason) =~ "brainstorm"
    assert Runs.get_run!(run.id).status == :failed
    refute_receive {:dispatched, _job}, 100
  end

  test "a failed run with no recorded executions is refused, naming the missing history", ctx do
    run = insert(:run, card: ctx.card, status: :failed, current_node: nil, flow_key: ctx.flow.key, flow_id: ctx.flow.id)

    assert {:error, {:unknown_node, "(none)"} = reason} = Runs.retry_run(run)
    assert Runs.retry_refusal_code(reason) == "unknown_node"
    assert Runs.retry_refusal_message(reason) =~ "no recorded node executions"
    refute_receive {:dispatched, _job}, 100
  end

  test "a running run is refused, naming its status", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{}}

    assert {:error, {:not_failed, :running} = reason} = Runs.retry_run(run)
    assert Runs.retry_refusal_code(reason) == "not_failed"
    assert Runs.retry_refusal_message(reason) =~ "running"
    assert Runs.get_run!(run.id).status == :running
  end

  test "a run whose card already has another active run is refused", ctx do
    run = failed_run(ctx.card, ctx.flow)
    insert(:run, card: Repo.get!(Schemas.Card, ctx.card.id), status: :running)

    assert {:error, :active_run_exists} = Runs.retry_run(run)
    assert Runs.get_run!(run.id).status == :failed
  end

  test "a run whose flow is gone is refused", ctx do
    run = failed_run(ctx.card, ctx.flow)
    run = run |> Ecto.Changeset.change(flow_id: nil) |> Repo.update!()

    assert {:error, :no_flow} = Runs.retry_run(run)
    assert Runs.get_run!(run.id).status == :failed
  end

  test "a retry grants exactly one more move, not a reset", ctx do
    run = failed_run(ctx.card, ctx.flow)
    {:ok, _revived} = Runs.retry_run(run)

    # One more attempt is allowed…
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, run} = Runs.report_outcome(job, %{outcome: :failed, detail: "still boom"})

    # …and the very next failure ends the run again — the budget was raised by one,
    # not restored.
    assert run.status == :failed
    assert Runs.get_run!(run.id).retries == 1
  end

  # NOTE: a module-level helper, NOT inside the describe block below — `defp` inside
  # `describe` is invalid Elixir. The shipped "code" flow is already `isolation:
  # :exclusive` (default_library.ex:52), so it needs no modification.
  defp exclusive_failed_run(ctx, executor_name) do
    card = Repo.get!(Schemas.Card, ctx.card.id)
    run = insert(:run, card: card, status: :failed, current_node: nil, flow_key: "code", flow_id: ctx.code_flow.id)

    execution = insert(:node_execution, run: run, node_key: "precommit", outcome: :failed, detail: "gate failed")

    insert(:node_job,
      node_execution: execution,
      state: :done,
      executor_name: executor_name,
      payload: %{"isolation" => "exclusive"}
    )

    Runs.get_run!(run.id)
  end

  describe "exclusive affinity" do
    setup ctx do
      %{code_flow: Relay.Flows.get_flow!(ctx.board, "code")}
    end

    test "the retry job is pinned to the executor that ran the last job", ctx do
      insert(:executor, board: ctx.board, name: "mac-holder")
      run = exclusive_failed_run(ctx, "mac-holder")

      {:ok, _revived} = Runs.retry_run(run)
      assert_receive {:dispatched, %NodeJob{executor_name: "mac-holder"}}
    end

    test "it refuses when the pinned executor has gone stale, naming it", ctx do
      insert(:executor,
        board: ctx.board,
        name: "mac-gone",
        interval: 30,
        last_heartbeat: DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)
      )

      run = exclusive_failed_run(ctx, "mac-gone")

      assert {:error, {:executor_unavailable, "mac-gone"} = reason} = Runs.retry_run(run)
      assert Runs.retry_refusal_code(reason) == "executor_unavailable"
      assert Runs.retry_refusal_message(reason) =~ "mac-gone"
      assert Runs.get_run!(run.id).status == :failed
      refute_receive {:dispatched, _job}, 100
    end

    test "it refuses when the pinned executor has never connected", ctx do
      run = exclusive_failed_run(ctx, "mac-never")
      assert {:error, {:executor_unavailable, "mac-never"}} = Runs.retry_run(run)
    end
  end
end
