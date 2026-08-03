defmodule Relay.Runs.RunServerTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.SubTask

  setup do
    # Supervisor started FIRST, before any card/run exists: its boot-time `resume_all/0`
    # reconciliation task queries `:running` runs exactly once, asynchronously. Starting it
    # before any run exists means that query can only ever see zero rows.
    start_supervised!(Relay.Runs.Supervisor)
    FakeDispatcher.register(self())
    :ok
  end

  # The Code flow's foreach lap in miniature (same edge shape as docs/designs/flows/code.json):
  # `branch` sits OUTSIDE the loop, `implement` is the foreach head, and BOTH reviews carry an
  # unguarded `--failed--> implement` loop-back. `quality_review` carries the two guarded
  # `succeeded` edges, which makes it the loop tail that checks each task off.
  defp code_shaped_flow_attrs do
    %{
      key: "code-shaped",
      isolation: :shared_clean,
      nodes: [
        %{key: "branch", type: :shell, run: "true"},
        %{key: "implement", type: :agent, run: "implement {sub_task}", foreach: "card.sub_tasks"},
        %{key: "spec_review", type: :agent, run: "spec review"},
        %{key: "quality_review", type: :agent, run: "quality review"},
        %{key: "precommit", type: :gate, run: "true"}
      ],
      edges: [
        %{from: "start", to: "branch"},
        %{from: "branch", to: "implement", on: :succeeded},
        %{from: "implement", to: "spec_review", on: :succeeded},
        %{from: "spec_review", to: "implement", on: :failed, max_loops: 3},
        %{from: "spec_review", to: "quality_review", on: :succeeded},
        %{from: "quality_review", to: "implement", on: :failed, max_loops: 3},
        %{from: "quality_review", to: "implement", on: :succeeded, when: :foreach_remaining},
        %{from: "quality_review", to: "precommit", on: :succeeded, when: :foreach_exhausted},
        %{from: "precommit", to: "done", on: :succeeded},
        %{from: "implement", to: "needs_input", on: :failed}
      ]
    }
  end

  # A board + enabled code-shaped flow + a card carrying a THREE-task plan, run started.
  # Mirrors runs_test.exs's setup_foreach/1; the card factory derives board_id from the stage.
  defp start_three_task_run do
    board = insert(:board)
    pulls = insert(:stage, board: board, name: "Plan:Done", position: 1)
    works = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 2)
    lands = insert(:stage, board: board, name: "Review", category: :in_progress, type: :review, position: 3)

    attrs =
      Map.merge(code_shaped_flow_attrs(), %{
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id
      })

    {:ok, flow} = Relay.Flows.create_flow(board, attrs)
    {:ok, flow} = Relay.Flows.enable_flow(flow)

    card = insert(:card, stage: pulls, plan: "### Task 1: Alpha\n\n### Task 2: Beta\n\n### Task 3: Gamma\n")

    {:ok, run} = Runs.start_run(card, flow)
    tasks = Repo.all(from st in SubTask, where: st.card_id == ^card.id, order_by: :position)

    %{run: run, card: card, tasks: tasks}
  end

  # The single in-flight (outcome-nil) execution — what the run is about to do next.
  defp pending(run) do
    Repo.one!(from e in NodeExecution, where: e.run_id == ^run.id and is_nil(e.outcome))
  end

  defp report(run, outcome, detail) do
    {:ok, _run} = Runs.report_outcome(Runs.active_job(run), %{outcome: outcome, detail: detail})
    :ok
  end

  # branch → implement: leaves the run on the foreach head, bound to the first undone task.
  defp past_branch(run), do: report(run, :succeeded, "branched")

  # implement → spec_review → quality_review for the CURRENT iteration; the run is left sitting
  # on quality_review, still bound to that iteration.
  defp drive_to_quality_review(run) do
    :ok = report(run, :succeeded, "implemented")
    :ok = report(run, :succeeded, "spec ok")
    :ok
  end

  # Iteration 1 start → finish: leaves the loop head bound to the SECOND task.
  defp complete_first_iteration(run) do
    :ok = past_branch(run)
    :ok = drive_to_quality_review(run)
    :ok = report(run, :succeeded, "quality ok")
    :ok
  end

  describe "the foreach cursor advances only on a :foreach_remaining edge (RE252)" do
    # The regression. `done` is not a private engine field — the drawer checkbox and
    # `relay check <ref> <id>` both write it — so a failure loop-back that RE-DERIVES the
    # cursor lands on the NEXT task and the reviewer's findings are delivered to nothing.
    test "a failed quality_review re-enters implement bound to the SAME task" do
      %{run: run, card: card, tasks: [_alpha, beta, _gamma]} = start_three_task_run()

      :ok = complete_first_iteration(run)
      assert pending(run).sub_task_id == beta.id

      # Iteration 2 reaches quality_review, and something OUTSIDE the engine checks Beta off
      # mid-flight — the drawer / `relay check` escape hatch decision 2 deliberately keeps.
      :ok = drive_to_quality_review(run)
      {:ok, _card} = Relay.Cards.set_sub_task_done(card, beta.id, true)

      :ok = report(run, :failed, "Beta's success branch has no test")

      next = pending(run)
      assert next.node_key == "implement"
      assert next.sub_task_id == beta.id

      # ...and the findings actually reach the re-run.
      assert Runs.active_job(run).payload["vars"]["findings"] == "Beta's success branch has no test"
    end

    test "a failed spec_review re-enters implement bound to the SAME task" do
      %{run: run, card: card, tasks: [_alpha, beta, _gamma]} = start_three_task_run()

      :ok = complete_first_iteration(run)
      assert pending(run).sub_task_id == beta.id

      # Iteration 2 fails at the FIRST review this time.
      :ok = report(run, :succeeded, "implemented")
      {:ok, _card} = Relay.Cards.set_sub_task_done(card, beta.id, true)
      :ok = report(run, :failed, "Beta is missing the migration")

      next = pending(run)
      assert next.node_key == "implement"
      assert next.sub_task_id == beta.id
      assert Runs.active_job(run).payload["vars"]["findings"] == "Beta is missing the migration"
    end

    @tag :capture_log
    test "an unrouted outcome degrading onto the :failed loop-back inherits the task too" do
      %{run: run, card: card, tasks: [_alpha, beta, _gamma]} = start_three_task_run()

      :ok = complete_first_iteration(run)
      :ok = drive_to_quality_review(run)
      {:ok, _card} = Relay.Cards.set_sub_task_done(card, beta.id, true)

      # `quality_review` declares no `:partial` edge, so RLY-179 degrades onto its
      # `--failed--> implement` edge — which must bind exactly as a real `:failed` does.
      :ok = report(run, :partial, "half-reviewed")

      next = pending(run)
      assert next.node_key == "implement"
      assert next.sub_task_id == beta.id
    end

    test "the success path still advances, and the exhausted guard still unbinds" do
      %{run: run, tasks: [alpha, beta, gamma]} = start_three_task_run()

      :ok = past_branch(run)
      assert pending(run).sub_task_id == alpha.id

      :ok = drive_to_quality_review(run)
      :ok = report(run, :succeeded, "alpha ok")
      assert Repo.get!(SubTask, alpha.id).done
      assert pending(run).sub_task_id == beta.id

      :ok = drive_to_quality_review(run)
      :ok = report(run, :succeeded, "beta ok")
      assert pending(run).sub_task_id == gamma.id

      # Last task: remaining hits 0, so the :foreach_exhausted edge leaves the loop unbound.
      :ok = drive_to_quality_review(run)
      :ok = report(run, :succeeded, "gamma ok")

      last = pending(run)
      assert last.node_key == "precommit"
      assert last.sub_task_id == nil
    end

    test "entering the foreach head from outside the loop resolves the first undone task" do
      %{run: run, tasks: [alpha, _beta, _gamma]} = start_three_task_run()

      # `branch` is not in the loop, so its execution carries no sub_task_id: the unguarded
      # edge into the head must fall back to the derived cursor.
      entry = pending(run)
      assert entry.node_key == "branch"
      assert entry.sub_task_id == nil

      :ok = past_branch(run)
      assert pending(run).sub_task_id == alpha.id
    end
  end
end
