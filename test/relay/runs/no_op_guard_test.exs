defmodule Relay.Runs.NoOpGuardTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  @base "base123"

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "No-op Guard Board"})
    start_supervised!(Relay.Runs.Supervisor)
    :ok = Runs.subscribe(board.id)
    %{board: board}
  end

  # A minimal marked flow: seed (shell) supplies the baseline sha, impl (agent) is
  # expects_commits with the real implement's retry-once-then-park shape.
  defp marked_flow(board, opts \\ []) do
    expects = Keyword.get(opts, :expects_commits, true)
    retries = Keyword.get(opts, :max_retries, 1)
    pulls = Enum.find(board.stages, &(&1.name == "Next up"))
    works = Enum.find(board.stages, &(&1.name == "Spec"))
    lands = Enum.find(board.stages, &(&1.name == "Plan"))

    impl_base = %{key: "impl", type: :agent, run: "impl {ref}", expects_commits: expects}
    impl = if retries, do: Map.put(impl_base, :max_retries, retries), else: impl_base

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "marked-#{System.unique_integer([:positive])}",
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id,
        nodes: [%{key: "seed", type: :shell, run: "true"}, impl],
        edges: [
          %{from: "start", to: "seed"},
          %{from: "seed", to: "impl", on: :succeeded},
          %{from: "impl", to: "done", on: :succeeded},
          %{from: "impl", to: "needs_input", on: :failed}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp card_in(board, stage_name) do
    stage = Enum.find(board.stages, &(&1.name == stage_name))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "no-op guard"})
    card
  end

  # Start the run and report the seed node succeeded with `sha`, returning the
  # dispatched impl job.
  defp seed_then_impl(board, flow, sha) do
    {:ok, _run} = Runs.start_run(card_in(board, "Next up"), flow)
    assert_receive {:dispatched, %NodeJob{node_key: "seed"} = seed}
    {:ok, _} = Runs.report_outcome(seed, %{outcome: :succeeded, detail: "ok", git_sha: sha})
    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = impl}
    impl
  end

  test "a marked node reporting succeeded with an unchanged sha is overridden to failed", ctx do
    flow = marked_flow(ctx.board)
    impl = seed_then_impl(ctx.board, flow, @base)

    {:ok, _run} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "all done", git_sha: @base})

    exec = Repo.get!(NodeExecution, impl.node_execution_id)
    assert exec.outcome == :failed
    assert exec.detail =~ "no_op_success: impl"
    assert exec.detail =~ "produced no commits"
    assert exec.failure_signature
  end

  test "an unmarked node reporting succeeded with an unchanged sha is left alone", ctx do
    flow = marked_flow(ctx.board, expects_commits: false)
    impl = seed_then_impl(ctx.board, flow, @base)

    {:ok, _run} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "done", git_sha: @base})

    exec = Repo.get!(NodeExecution, impl.node_execution_id)
    assert exec.outcome == :succeeded
  end

  test "a marked node whose sha moved keeps its succeeded outcome", ctx do
    flow = marked_flow(ctx.board)
    impl = seed_then_impl(ctx.board, flow, @base)

    {:ok, _run} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "done", git_sha: "moved99"})

    exec = Repo.get!(NodeExecution, impl.node_execution_id)
    assert exec.outcome == :succeeded
  end

  test "a nil reported sha fails open (no override)", ctx do
    flow = marked_flow(ctx.board)
    impl = seed_then_impl(ctx.board, flow, @base)

    {:ok, _run} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "done"})

    exec = Repo.get!(NodeExecution, impl.node_execution_id)
    assert exec.outcome == :succeeded
  end

  test "a nil baseline sha fails open (no override)", ctx do
    flow = marked_flow(ctx.board)
    # Report seed with NO git_sha, so there is no baseline.
    {:ok, _run} = Runs.start_run(card_in(ctx.board, "Next up"), flow)
    assert_receive {:dispatched, %NodeJob{node_key: "seed"} = seed}
    {:ok, _} = Runs.report_outcome(seed, %{outcome: :succeeded, detail: "ok"})
    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = impl}

    {:ok, _run} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "done", git_sha: @base})

    exec = Repo.get!(NodeExecution, impl.node_execution_id)
    assert exec.outcome == :succeeded
  end

  test "a no-op marked node parks the run after spending its one retry", ctx do
    flow = marked_flow(ctx.board)
    impl = seed_then_impl(ctx.board, flow, @base)

    # First no-op success → override to failed → retry (max_retries 1), run still running.
    {:ok, %{status: :running}} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "x", git_sha: @base})
    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = retry}

    # Second no-op success → override to failed → retry spent → route impl → needs_input → park.
    {:ok, run} = Runs.report_outcome(retry, %{outcome: :succeeded, detail: "x", git_sha: @base})
    assert run.status == :parked
    assert run.parked_reason == :needs_input
    assert_receive {:run_parked, %Schemas.Run{}}
    # Parked, NOT ended with no_route_for_outcome: a park leaves failure_detail nil.
    assert run.failure_detail == nil
  end

  test "an overridden loop-tail node leaves its sub_task box unchecked", ctx do
    # A foreach flow whose marked head is also the loop tail: on a real success it would
    # check the sub_task off, but the override makes it :failed, so the box stays unchecked.
    board = ctx.board
    pulls = Enum.find(board.stages, &(&1.name == "Next up"))
    works = Enum.find(board.stages, &(&1.name == "Spec"))
    lands = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "marked-foreach-#{System.unique_integer([:positive])}",
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id,
        nodes: [
          %{key: "seed", type: :shell, run: "true"},
          %{key: "impl", type: :agent, run: "impl {ref}", expects_commits: true, foreach: "card.sub_tasks"}
        ],
        edges: [
          %{from: "start", to: "seed"},
          %{from: "seed", to: "impl", on: :succeeded},
          %{from: "impl", to: "impl", on: :succeeded, when: :foreach_remaining},
          %{from: "impl", to: "done", on: :succeeded, when: :foreach_exhausted},
          %{from: "impl", to: "needs_input", on: :failed}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)

    card = card_in(board, "Next up")
    sub_task = insert(:sub_task, card: card, done: false)

    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{node_key: "seed"} = seed}
    {:ok, _} = Runs.report_outcome(seed, %{outcome: :succeeded, detail: "ok", git_sha: @base})
    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = impl}

    {:ok, _run} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "x", git_sha: @base})

    assert Repo.get!(Schemas.SubTask, sub_task.id).done == false
  end

  test "a failed brainstorm parks the Spec run instead of ending it (criterion 3)", ctx do
    {:ok, flow} = ctx.board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    {:ok, _run} = Runs.start_run(card_in(ctx.board, "Next up"), flow)

    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"} = j1}
    {:ok, %{status: :running}} = Runs.report_outcome(j1, %{outcome: :failed, detail: "boom-1"})
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"} = j2}
    {:ok, run} = Runs.report_outcome(j2, %{outcome: :failed, detail: "boom-2"})

    assert run.status == :parked
    assert run.parked_reason == :needs_input
  end

  test "a reviewer's failed routes to its fix node on the first failure — no retry, no park (criterion 5)", ctx do
    # Pure engine assertion against the DB-round-tripped code flow: quality_review has no
    # max_retries, so its :failed routes straight to implement (not a retry, not a park).
    code = Relay.Flows.get_flow!(ctx.board, "code")

    current = %{
      node_key: "quality_review",
      visit: 1,
      attempt: 1,
      outcome: :failed,
      failure_signature: "sig",
      sub_task_id: nil
    }

    assert Relay.Runs.Engine.decide(code, [current], current) == {:transition, "implement"}
  end
end
