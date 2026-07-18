defmodule Relay.Runs.CodeFlowE2ETest do
  @moduledoc """
  RLY-139 / W13 — the Code flow, proved end to end over the real REST API with no
  `claude` invocation: a card in *Plan:Done* is dispatched by the server-side
  scheduler, its plan is parsed into sub_tasks, and a scripted executor walks the
  whole graph (branch → N × (implement → spec_review → quality_review) → precommit →
  final_review → smoke → acceptance → post → merge) claiming over
  `POST /api/node-jobs/claim` and reporting over `POST /api/node-jobs/:id/outcome`.

  Modelled on `test/relay_web/api/plan_flow_e2e_test.exs` (W12) and
  `test/relay_web/api/spec_flow_e2e_test.exs` (W11); uses W11's
  `Relay.Runs.Scheduler.ScriptedExecutor` harness for the HTTP calls.
  """
  use RelayWeb.ConnCase, async: false

  import Ecto.Query

  alias Relay.Cards
  alias Relay.Flows
  alias Relay.Repo
  alias Relay.Runs
  alias Relay.Runs.Capacity
  alias Relay.Runs.Listener
  alias Relay.Runs.Scheduler.ScriptedExecutor, as: Exec
  alias Relay.Runs.Scheduler.Server
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.SubTask

  @executor_name "code-e2e-executor"
  @capacity %{"shared_clean" => 0, "exclusive" => 1}

  setup %{conn: conn} do
    Capacity.reset()
    start_supervised!(Relay.Runs.Supervisor)

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Code Cutover Board"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)

    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    :ok = Runs.subscribe(board.id)

    %{conn: conn, board: board}
  end

  defp stage(board, name), do: Enum.find(board.stages, &(&1.name == name))

  defp plan_with(titles) do
    titles
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {title, n} -> "### Task #{n}: #{title}\n\n- [ ] do it" end)
  end

  defp code_card(board, titles) do
    {:ok, card} = Cards.create_card(stage(board, "Plan:Done"), %{title: "Ship the thing"})
    {:ok, card} = Cards.update_card(card, %{plan: plan_with(titles)})
    card
  end

  defp announce(conn, board) do
    assert Exec.claim(conn, @executor_name, @capacity) == nil
    executor = Repo.get_by!(Schemas.Executor, board_id: board.id, name: @executor_name)
    :ok = Capacity.put(executor.id, %{shared_clean: 0, exclusive: 1})
    executor
  end

  defp start_scheduler(board) do
    start_supervised!({Server, [board_id: board.id, tick_ms: 3_600_000, debounce_ms: 5, name: :"code_e2e_#{board.id}"]})
  end

  # See plan_flow_e2e_test.exs's settle/1: drain the Listener and the per-test
  # scheduler so neither is mid-query when the sandbox tears down. Always called
  # AFTER an assert_receive on the run's terminal broadcast.
  defp settle(server) do
    _ = :sys.get_state(Process.whereis(Listener))
    _ = :sys.get_state(server)
    :ok
  end

  defp launch(conn, board, titles) do
    {:ok, _flow} = board |> Flows.get_flow!("code") |> Flows.enable_flow()
    card = code_card(board, titles)
    announce(conn, board)
    server = start_scheduler(board)
    :ok = Server.reconcile_now(server)
    [run] = Runs.active_runs(board.id)
    %{card: card, run: run, server: server}
  end

  # Claim/report until the run leaves :running. `script` maps a node_key to a queue
  # of {outcome, detail} to hand back; an exhausted or absent queue means
  # {"succeeded", "ok"}. Returns every claimed payload, in order.
  defp drive(conn, script, acc \\ []) do
    case Exec.claim(conn, @executor_name, @capacity) do
      nil ->
        Enum.reverse(acc)

      body ->
        {outcome, detail, script} = pop(script, body["node_id"])
        %{"run_state" => state} = Exec.outcome(conn, body["id"], %{"outcome" => outcome, "detail" => detail})
        acc = [body | acc]

        if state in ["done", "failed", "parked"],
          do: Enum.reverse(acc),
          else: drive(conn, script, acc)
    end
  end

  defp pop(script, node_key) do
    case Map.get(script, node_key, []) do
      [{outcome, detail} | rest] -> {outcome, detail, Map.put(script, node_key, rest)}
      [] -> {"succeeded", "ok", script}
    end
  end

  defp executions(run), do: Repo.all(from e in NodeExecution, where: e.run_id == ^run.id, order_by: [asc: e.id])

  defp sub_tasks(card), do: Repo.all(from st in SubTask, where: st.card_id == ^card.id, order_by: [asc: st.position])

  defp progress(board, card), do: Cards.sub_task_progress(Repo.preload(Cards.get_card(board, card.id), :sub_tasks))

  describe "the Code flow, end to end" do
    test "a 3-task plan is iterated, each task is checked off, and the run reaches :done",
         %{conn: conn, board: board} do
      %{card: card, run: run, server: server} = launch(conn, board, ["Alpha", "Beta", "Gamma"])

      # The engine owns the task list: start_run parsed the plan.
      assert ["Alpha", "Beta", "Gamma"] = Enum.map(sub_tasks(card), & &1.title)
      assert progress(board, card) == %{done: 0, total: 3}

      claimed = drive(conn, %{})

      # branch, 3 × (implement, spec_review, quality_review), then the tail.
      assert Enum.map(claimed, & &1["node_id"]) == [
               "branch",
               "implement",
               "spec_review",
               "quality_review",
               "implement",
               "spec_review",
               "quality_review",
               "implement",
               "spec_review",
               "quality_review",
               "precommit",
               "final_review",
               "smoke",
               "acceptance",
               "post",
               "merge"
             ]

      # No next_task gate anywhere in the walk.
      refute "next_task" in Enum.map(claimed, & &1["node_id"])

      # Each implement carried the sub_task it was working, in order.
      assert ["Alpha", "Beta", "Gamma"] =
               claimed |> Enum.filter(&(&1["node_id"] == "implement")) |> Enum.map(& &1["vars"]["sub_task"])

      # ...and each iteration's executions are stamped with that sub_task's id.
      ids = Enum.map(sub_tasks(card), & &1.id)

      assert Enum.map(executions(run), &{&1.node_key, &1.sub_task_id}) == [
               {"branch", nil},
               {"implement", Enum.at(ids, 0)},
               {"spec_review", Enum.at(ids, 0)},
               {"quality_review", Enum.at(ids, 0)},
               {"implement", Enum.at(ids, 1)},
               {"spec_review", Enum.at(ids, 1)},
               {"quality_review", Enum.at(ids, 1)},
               {"implement", Enum.at(ids, 2)},
               {"spec_review", Enum.at(ids, 2)},
               {"quality_review", Enum.at(ids, 2)},
               {"precommit", nil},
               {"final_review", nil},
               {"smoke", nil},
               {"acceptance", nil},
               {"post", nil},
               {"merge", nil}
             ]

      assert Runs.get_run!(run.id).status == :done
      assert progress(board, card) == %{done: 3, total: 3}

      assert_receive {:run_finished, %{id: finished_id}}, 5_000
      assert finished_id == run.id
      settle(server)
    end

    test "a refuted review loops back to implement with the findings, leaving the task undone",
         %{conn: conn, board: board} do
      %{card: card, run: run, server: server} = launch(conn, board, ["Alpha"])

      assert %{"node_id" => "branch"} = branch = Exec.claim(conn, @executor_name, @capacity)
      Exec.outcome(conn, branch["id"], %{"outcome" => "succeeded", "detail" => "ok"})

      assert %{"node_id" => "implement"} = impl = Exec.claim(conn, @executor_name, @capacity)
      Exec.outcome(conn, impl["id"], %{"outcome" => "succeeded", "detail" => "ok"})

      assert %{"node_id" => "spec_review"} = review = Exec.claim(conn, @executor_name, @capacity)
      Exec.outcome(conn, review["id"], %{"outcome" => "failed", "detail" => "the second assertion is missing"})

      # The refusal routes straight back to implement, carrying the findings.
      assert %{"node_id" => "implement"} = again = Exec.claim(conn, @executor_name, @capacity)
      assert again["vars"]["findings"] == "the second assertion is missing"
      assert again["vars"]["sub_task"] == "Alpha"

      # The task is NOT checked off — the box means "reviewed", not "attempted".
      assert [%{done: false}] = sub_tasks(card)
      assert Runs.get_run!(run.id).status == :running

      assert_receive {:run_started, _}, 5_000
      settle(server)
    end

    test "loop exhaustion within one task fails the run and puts the FINDINGS on the card",
         %{conn: conn, board: board} do
      %{card: card, run: run, server: server} = launch(conn, board, ["Alpha"])

      # quality_review --failed--> implement carries max_loops: 3, so the 4th
      # refusal on the same task exhausts it. Each refusal's text is distinct
      # so the (deliberately global) circuit breaker — which trips at 3
      # IDENTICAL failures — doesn't fire before the loop budget does.
      findings = "still no coverage for the error branch"

      script = %{
        "spec_review" => [],
        "quality_review" => for(n <- 1..4, do: {"failed", "#{findings} (attempt #{n})"})
      }

      drive(conn, script)

      run = Runs.get_run!(run.id)
      assert run.status == :failed
      assert run.failure_detail =~ "loop_budget_exhausted"

      card = Cards.get_card(board, card.id)
      assert card.status == :needs_input

      # The refuting reviewer's text reaches the card — not merely the engine's
      # reason string (decision 4).
      assert Repo.exists?(from c in Schemas.Comment, where: c.card_id == ^card.id and ilike(c.body, ^"%#{findings}%"))

      assert_receive {:run_finished, %{id: failed_id}}, 5_000
      assert failed_id == run.id
      settle(server)
    end

    test "each task gets its own full loop budget — the W11 run's real shape",
         %{conn: conn, board: board} do
      # W11's own /exec-plan run took 3 review-fix laps on task 1 and 3 more on
      # task 2. Under whole-run budget accounting that run hard-fails partway
      # through task 2; under per-iteration accounting it must reach :done.
      # Each lap's text is distinct — see the loop-exhaustion test above for
      # why identical text would trip the global breaker instead. The queue
      # is shared by node_id across BOTH iterations (`drive/3` doesn't know
      # about sub_tasks), so task 1's 4th (successful) visit is an explicit
      # entry — leaving it to the default would instead hand task 1 task 2's
      # first scripted failure.
      %{card: card, run: run, server: server} = launch(conn, board, ["Alpha", "Beta"])

      script = %{
        "quality_review" =>
          for(n <- 1..3, do: {"failed", "task 1 lap #{n}"}) ++
            [{"succeeded", "ok"}] ++
            for(n <- 1..3, do: {"failed", "task 2 lap #{n}"})
      }

      drive(conn, script)

      assert Runs.get_run!(run.id).status == :done
      assert progress(board, card) == %{done: 2, total: 2}

      # Both tasks really did burn laps — the budget reset, it wasn't bypassed.
      by_task = Enum.group_by(executions(run), & &1.sub_task_id)
      [alpha, beta] = sub_tasks(card)
      assert Enum.count(by_task[alpha.id], &(&1.node_key == "implement")) == 4
      assert Enum.count(by_task[beta.id], &(&1.node_key == "implement")) == 4

      assert_receive {:run_finished, %{id: finished_id}}, 5_000
      assert finished_id == run.id
      settle(server)
    end

    test "merge is unreachable while precommit is red", %{conn: conn, board: board} do
      %{run: run, server: server} = launch(conn, board, ["Alpha"])

      # Walk the single iteration by hand up to the gate, so the assertion below
      # happens WHILE precommit is red rather than after final_fix has healed it.
      for node <- ["branch", "implement", "spec_review", "quality_review"] do
        body = Exec.claim(conn, @executor_name, @capacity)
        assert body["node_id"] == node
        Exec.outcome(conn, body["id"], %{"outcome" => "succeeded", "detail" => "ok"})
      end

      assert %{"node_id" => "precommit"} = gate = Exec.claim(conn, @executor_name, @capacity)
      Exec.outcome(conn, gate["id"], %{"outcome" => "failed", "detail" => "3 tests failing"})

      # The red gate routes to final_fix, and no merge job exists for this run.
      assert %{"node_id" => "final_fix"} = fix = Exec.claim(conn, @executor_name, @capacity)
      refute Repo.exists?(from j in NodeJob, where: j.run_id == ^run.id and j.node_key == "merge")
      assert fix["vars"]["findings"] == "3 tests failing"

      # Let the run finish so the sandbox tears down against a terminal run.
      Exec.outcome(conn, fix["id"], %{"outcome" => "succeeded", "detail" => "fixed"})
      drive(conn, %{})

      assert Runs.get_run!(run.id).status == :done

      assert_receive {:run_finished, %{id: finished_id}}, 5_000
      assert finished_id == run.id
      settle(server)
    end
  end
end
