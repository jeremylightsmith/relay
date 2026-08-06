defmodule Relay.Runs.ReenterFindingsTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Relay.Runs.Instance
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  @base "base123"

  setup do
    # Supervisor started FIRST, before any card/run exists: its boot-time
    # `resume_all/0` reconciliation task queries `:running` runs exactly once,
    # asynchronously. Starting it before this run exists means that query can
    # only ever see zero rows — started after, it can race the still-in-flight
    # `start_run` below and re-enter the same brand-new run a second time.
    start_engine!()
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Re-entry Board"})
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    # The scripted executor here runs no real skill, so the card arrives already carrying the
    # fields the shipped spec flow declares it writes (RE244) — otherwise every `succeeded` is
    # rewritten to `failed` by the missing-writes guard.
    {:ok, card} =
      Relay.Cards.create_card(stage, %{
        title: "Carry the failure forward",
        spec: "# Spec (pre-seeded — the spec flow's brainstorm declares it writes this, RE244)",
        acceptance_criteria: "1. It works."
      })

    %{board: board, flow: flow, card: card}
  end

  # RLY-189 acceptance 2: a re-entered node must know why it is running again.
  test "a same-visit re-entry carries the last failure's detail as findings", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{} = job}

    # brainstorm has max_retries: 1, so this failure re-enters the node rather than
    # ending the run — and the RE-DISPATCHED job is the one under test.
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :failed, detail: "the gate said no"})
    assert_receive {:dispatched, %NodeJob{node_execution_id: id, payload: payload}}
    assert payload["vars"]["findings"] == "the gate said no"

    execution = Repo.get!(NodeExecution, id)
    assert execution.run_id == run.id
    assert execution.visit == 1
    assert execution.attempt == 2
  end

  test "a fresh-visit re-entry enters at attempt 1 on a new visit and carries findings", ctx do
    {:ok, _run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :failed, detail: "boom"})
    assert_receive {:dispatched, %NodeJob{} = retried}
    {:ok, run} = Runs.report_outcome(retried, %{outcome: :failed, detail: "boom again"})

    # The run is terminal now; drive the new mode directly.
    run = run |> Ecto.Changeset.change(status: :running, current_node: "brainstorm") |> Repo.update!()

    instance = Instance.current()

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        instance.run_supervisor,
        {Relay.Runs.RunServer,
         run_id: run.id, mode: {:reenter_new_visit, nil}, registry: instance.registry, callers: Instance.callers()}
      )

    assert_receive {:dispatched, %NodeJob{node_execution_id: id, payload: payload}}
    execution = Repo.get!(NodeExecution, id)
    assert execution.visit == 2
    assert execution.attempt == 1
    assert payload["vars"]["findings"] == "boom again"
    assert payload["resume_session"] == nil
  end

  test "a re-entry after a SUCCEEDED execution carries no findings", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "?", session_id: "s1"})

    run = Runs.get_run!(run.id)
    {:ok, _run} = Runs.resume_run(run, resume_session: "s1")

    assert_receive {:dispatched, %NodeJob{payload: payload}}
    assert payload["vars"]["findings"] == nil
    assert payload["resume_session"] == "s1"
  end

  # seed (shell, supplies the baseline sha) → review (agent) → impl (agent, expects_commits, two
  # retries). `review` declares no max_retries, so its :failed TRANSITIONS to impl rather than
  # retrying — and that transition is what sets impl's ORIGIN findings.
  defp guarded_flow(board) do
    build_flow(
      board,
      "guarded",
      [
        %{key: "seed", type: :shell, run: "true"},
        %{key: "review", type: :agent, run: "review {ref}"},
        %{key: "impl", type: :agent, run: "impl {ref}", expects_commits: true, max_retries: 2}
      ],
      [
        %{from: "start", to: "seed"},
        %{from: "seed", to: "review", on: :succeeded},
        %{from: "review", to: "impl", on: :failed},
        %{from: "review", to: "done", on: :succeeded},
        %{from: "impl", to: "done", on: :succeeded},
        %{from: "impl", to: "needs_input", on: :failed}
      ]
    )
  end

  # seed (shell) → work (agent, one retry). `work` is entered from a SUCCEEDED seed, so a retry of
  # it has no origin — the path that must stay byte-identical to before RE251.
  defp clean_entry_flow(board) do
    build_flow(
      board,
      "clean-entry",
      [
        %{key: "seed", type: :shell, run: "true"},
        %{key: "work", type: :agent, run: "work {ref}", max_retries: 1}
      ],
      [
        %{from: "start", to: "seed"},
        %{from: "seed", to: "work", on: :succeeded},
        %{from: "work", to: "done", on: :succeeded},
        %{from: "work", to: "needs_input", on: :failed}
      ]
    )
  end

  defp build_flow(board, key, nodes, edges) do
    pulls = Enum.find(board.stages, &(&1.name == "Next up"))
    works = Enum.find(board.stages, &(&1.name == "Spec"))
    lands = Enum.find(board.stages, &(&1.name == "Plan"))

    # setup/0 already enables "spec" pulling from "Next up" — disable it first so this flow
    # (also pulling from "Next up") doesn't collide with the one-enabled-flow-per-pulls_from
    # unique index (same pattern as runs_engine_test.exs).
    if spec = Relay.Flows.get_flow(board, "spec"), do: Relay.Flows.disable_flow(spec)

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "#{key}-#{System.unique_integer([:positive])}",
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id,
        nodes: nodes,
        edges: edges
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  # Start a fresh card on `flow` and report the seed node succeeded with the baseline sha.
  defp start_and_seed(board, flow, title) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: title})
    {:ok, _run} = Runs.start_run(card, flow)

    assert_receive {:dispatched, %NodeJob{node_key: "seed"} = seed}
    {:ok, _} = Runs.report_outcome(seed, %{outcome: :succeeded, detail: "ok", git_sha: @base})
    :ok
  end

  # Drive seed → review(failed) and return the dispatched impl job, asserting the transition
  # already carries the reviewer's words (the path that has always worked).
  defp review_sends_back(board, flow, findings) do
    :ok = start_and_seed(board, flow, "guarded")

    assert_receive {:dispatched, %NodeJob{node_key: "review"} = review}
    {:ok, _} = Runs.report_outcome(review, %{outcome: :failed, detail: findings, git_sha: @base})

    assert_receive {:dispatched, %NodeJob{node_key: "impl", payload: payload} = impl}
    assert payload["vars"]["findings"] == findings
    impl
  end

  # RE251: a retry must carry the ORIGINATING findings, not only the latest failure. The commit
  # guard's no-op message is what `execution.detail` holds when attempt 1 "fails", so handing only
  # that forward loses the reviewer's words from attempt 2 on and each retry drifts further from
  # the real problem.
  describe "a retry after a guard-flipped no-op" do
    test "carries BOTH the reviewer's findings and the attempt's failure detail", ctx do
      flow = guarded_flow(ctx.board)
      impl = review_sends_back(ctx.board, flow, "assert on CSV bytes, not the struct")

      # A no-op success: the guard rewrites it to :failed with its own message, then retries.
      {:ok, _run} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "nothing to do", git_sha: @base})

      assert_receive {:dispatched, %NodeJob{node_key: "impl", payload: payload}}
      findings = payload["vars"]["findings"]

      assert findings =~ "assert on CSV bytes, not the struct"
      assert findings =~ "produced no commits"
      assert findings =~ "no_op_success: impl"
    end

    test "a second retry carries the originating findings exactly once", ctx do
      flow = guarded_flow(ctx.board)
      impl = review_sends_back(ctx.board, flow, "assert on CSV bytes, not the struct")

      {:ok, _run} = Runs.report_outcome(impl, %{outcome: :succeeded, detail: "x", git_sha: @base})
      assert_receive {:dispatched, %NodeJob{node_key: "impl"} = second}

      {:ok, _run} = Runs.report_outcome(second, %{outcome: :succeeded, detail: "x", git_sha: @base})
      assert_receive {:dispatched, %NodeJob{node_key: "impl", payload: payload}}

      findings = payload["vars"]["findings"]
      # Re-derived from history, never read back off the previous attempt's merged payload —
      # otherwise the origin compounds on every retry.
      assert length(String.split(findings, "assert on CSV bytes, not the struct")) == 2
      assert findings =~ "produced no commits"
    end

    test "a retry of a node NOT entered from a failure is unchanged", ctx do
      flow = clean_entry_flow(ctx.board)
      :ok = start_and_seed(ctx.board, flow, "clean entry")

      assert_receive {:dispatched, %NodeJob{node_key: "work"} = work}
      {:ok, _run} = Runs.report_outcome(work, %{outcome: :failed, detail: "the gate said no"})

      # Entered from a SUCCEEDED seed ⇒ no origin ⇒ byte-identical to before RE251.
      assert_receive {:dispatched, %NodeJob{node_key: "work", payload: payload}}
      assert payload["vars"]["findings"] == "the gate said no"
    end
  end
end
