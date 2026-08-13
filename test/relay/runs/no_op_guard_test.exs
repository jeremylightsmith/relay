defmodule Relay.Runs.NoOpGuardTest do
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  @base "base123"

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "No-op Guard Board"})
    start_engine!()
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

  test "a retry keeps succeeded when an earlier attempt of the same visit made the commit", ctx do
    # RE298: attempt 1 committed `moved99` and then died before writing its outcome file, so it
    # was recorded :failed carrying the POST-work sha. Attempt 2 finds the work already done and
    # can no longer move HEAD — baselining on attempt 1 would make it structurally impossible to
    # pass the guard, and the only way out would be to fabricate a commit. The baseline is the
    # sha before attempt 1 of this visit, so the visit's real commit still counts.
    flow = marked_flow(ctx.board)
    impl = seed_then_impl(ctx.board, flow, @base)

    {:ok, %{status: :running}} =
      Runs.report_outcome(impl, %{outcome: :failed, detail: "died before reporting", git_sha: "moved99"})

    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = retry}

    {:ok, _run} = Runs.report_outcome(retry, %{outcome: :succeeded, detail: "already done", git_sha: "moved99"})

    exec = Repo.get!(NodeExecution, retry.node_execution_id)
    assert exec.outcome == :succeeded
  end

  test "a retry that commits nothing is still caught when the whole visit moved no commits", ctx do
    # The guard keeps its teeth: attempt 1 failed WITHOUT committing, so the visit's baseline is
    # still @base and attempt 2's unchanged sha is a genuine no-op.
    flow = marked_flow(ctx.board)
    impl = seed_then_impl(ctx.board, flow, @base)

    {:ok, %{status: :running}} =
      Runs.report_outcome(impl, %{outcome: :failed, detail: "died before reporting", git_sha: @base})

    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = retry}

    {:ok, _run} = Runs.report_outcome(retry, %{outcome: :succeeded, detail: "x", git_sha: @base})

    exec = Repo.get!(NodeExecution, retry.node_execution_id)
    assert exec.outcome == :failed
    assert exec.detail =~ "no_op_success: impl"
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

  # RE310 — the RE306 shape: `impl` commits, a reviewer bounces it, and the loop-back opens a NEW
  # visit whose baseline IS the commit `impl` just made. `foreach?` picks the flavour: with a
  # foreach the binding is {node, sub_task}, without one it is the node's first visit in the run.
  # ONE flow definition, two bindings — the rule under test is general to every expects_commits
  # node (implement, final_fix, smoke_fix, acceptance_fix), not special-cased to foreach.
  #
  # Note `impl` is NOT the loop tail here (the `when` guards sit on `review`), so a successful
  # impl does not check its sub_task off — which is precisely the state that armed RE306.
  defp looping_flow(board, foreach?) do
    pulls = Enum.find(board.stages, &(&1.name == "Next up"))
    works = Enum.find(board.stages, &(&1.name == "Spec"))
    lands = Enum.find(board.stages, &(&1.name == "Plan"))

    impl = %{key: "impl", type: :agent, run: "impl {ref}", expects_commits: true}
    impl = if foreach?, do: Map.put(impl, :foreach, "card.sub_tasks"), else: impl

    loop_edges =
      if foreach? do
        [
          %{from: "review", to: "impl", on: :succeeded, when: :foreach_remaining},
          %{from: "review", to: "done", on: :succeeded, when: :foreach_exhausted}
        ]
      else
        [%{from: "review", to: "done", on: :succeeded}]
      end

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "looping-#{System.unique_integer([:positive])}",
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id,
        nodes: [
          %{key: "seed", type: :shell, run: "true"},
          impl,
          %{key: "review", type: :agent, run: "review {ref}"}
        ],
        edges:
          [
            %{from: "start", to: "seed"},
            %{from: "seed", to: "impl", on: :succeeded},
            %{from: "impl", to: "review", on: :succeeded},
            %{from: "impl", to: "needs_input", on: :failed},
            %{from: "review", to: "impl", on: :failed, max_loops: 3}
          ] ++ loop_edges
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  # Drives the RE306 sequence up to the re-entered visit and returns THAT visit's job: seed
  # baselines at @base, impl commits `sha`, review fails carrying the SAME sha, the loop-back
  # opens visit 2 still bound to task 1. Sub_tasks are inserted BEFORE start_run — a foreach flow
  # refuses to start without them (failures.md B1).
  defp reentered_after_commit(board, flow, sha, sub_task_count) do
    card = card_in(board, "Next up")
    for position <- 1..sub_task_count//1, do: insert(:sub_task, card: card, position: position)

    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{node_key: "seed"} = seed}
    {:ok, _} = Runs.report_outcome(seed, %{outcome: :succeeded, detail: "ok", git_sha: @base})

    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = impl}
    {:ok, _} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "task 1", git_sha: sha})

    assert_receive {:dispatched, %NodeJob{node_key: "review"} = review}
    {:ok, _} = Runs.report_outcome(review, %{outcome: :failed, detail: "a finding", git_sha: sha})

    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = reentered}
    reentered
  end

  test "RE310: a re-entered visit whose task is already committed may assert --no-changes", ctx do
    # The full RE306 sequence, foreach flavour: impl v1 commits `moved99` and never checks its
    # sub_task off, the reviewer fails, and impl v2's baseline IS `moved99`. Without the assertion
    # every exit is closed; with it, the engine corroborates the claim against its own history
    # (impl already committed for THIS sub_task) and honours it.
    flow = looping_flow(ctx.board, true)
    reentered = reentered_after_commit(ctx.board, flow, "moved99", 2)

    {:ok, _run} =
      Runs.report_outcome(reentered, %{
        outcome: :succeeded,
        detail: "already committed",
        git_sha: "moved99",
        no_changes: true
      })

    exec = Repo.get!(NodeExecution, reentered.node_execution_id)
    assert exec.outcome == :succeeded
    assert exec.no_changes == true
  end

  test "RE310: the same escape works on a non-foreach expects_commits node", ctx do
    # `final_fix` / `smoke_fix` / `acceptance_fix` sit on the identical loop-back with no
    # sub_tasks at all, so the binding is the node's first visit in this run.
    flow = looping_flow(ctx.board, false)
    reentered = reentered_after_commit(ctx.board, flow, "moved99", 0)

    {:ok, _run} =
      Runs.report_outcome(reentered, %{
        outcome: :succeeded,
        detail: "already committed",
        git_sha: "moved99",
        no_changes: true
      })

    exec = Repo.get!(NodeExecution, reentered.node_execution_id)
    assert exec.outcome == :succeeded
  end

  test "RE310: a first-visit --no-changes claim is still rewritten to failed", ctx do
    # The constraint that makes the fix non-trivial: on a node's FIRST visit for a binding the
    # binding baseline EQUALS the visit baseline, so a node that has never committed anything
    # cannot assert its way past the guard (RLY-194's original case, unchanged).
    flow = marked_flow(ctx.board)
    impl = seed_then_impl(ctx.board, flow, @base)

    {:ok, _run} =
      Runs.report_outcome(impl, %{outcome: :succeeded, detail: "nothing to do", git_sha: @base, no_changes: true})

    exec = Repo.get!(NodeExecution, impl.node_execution_id)
    assert exec.outcome == :failed
    assert exec.detail =~ "no_changes_unproven: impl"
    # The CLAIM is recorded even though the engine disagreed — that is what makes "the agent
    # asserted this and the engine rejected it" readable after the fact.
    assert exec.no_changes == true
  end

  test "RE310: the dead-end failure names the exit instead of repeating 'no commits'", ctx do
    # The same re-entered visit WITHOUT a claim. This detail is what a retry reads as its
    # findings (RE251), and it is the just-in-time channel that teaches the flag.
    flow = looping_flow(ctx.board, true)
    reentered = reentered_after_commit(ctx.board, flow, "moved99", 2)

    {:ok, _run} =
      Runs.report_outcome(reentered, %{outcome: :succeeded, detail: "nothing left", git_sha: "moved99"})

    exec = Repo.get!(NodeExecution, reentered.node_execution_id)
    assert exec.outcome == :failed
    assert exec.detail =~ "committed already"
    assert exec.detail =~ "relay outcome succeeded --no-changes"
    assert exec.detail =~ "no_op_success: impl"
    assert exec.no_changes == false
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

    assert Relay.Runs.Engine.decide(code, [current], current) == {:transition, "implement", nil}
  end
end
