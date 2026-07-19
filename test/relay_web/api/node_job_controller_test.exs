defmodule RelayWeb.Api.NodeJobControllerTest do
  use RelayWeb.ConnCase, async: false

  import Ecto.Query

  alias Relay.Runs
  alias Relay.Runs.Capacity
  alias Relay.Runs.FakeDispatcher

  setup %{conn: conn} do
    FakeDispatcher.register(self())
    start_supervised!(Relay.Runs.Supervisor)

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Node Board"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
    :ok = Runs.subscribe(board.id)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, board: board}
  end

  # A one-node flow with an edge for every terminal outcome → deterministic routing.
  defp four_outcome_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    plan = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "four",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: plan.id,
        nodes: [%{key: "work", type: :agent, run: "work {ref}", agent: "plan-implementer"}],
        edges: [
          %{from: "start", to: "work"},
          %{from: "work", to: "done", on: :succeeded},
          %{from: "work", to: "done", on: :failed},
          %{from: "work", to: "done", on: :partial}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp start_queued_job(board, flow) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Do work"})
    {:ok, run} = Runs.start_run(card, flow)
    {run, Runs.active_job(run)}
  end

  defp claim(conn, capacity \\ %{"shared_clean" => 1, "exclusive" => 1}) do
    post(
      conn,
      ~p"/api/node-jobs/claim",
      Jason.encode!(%{
        "executor" => %{"name" => "fake", "host" => "fake", "interval" => 30},
        "capacity" => capacity
      })
    )
  end

  # Module-level helper (ExUnit forbids defp inside describe): claim a fresh job, return {run, id}.
  defp claim_one(conn, board, flow) do
    {run, _job} = start_queued_job(board, flow)
    body = conn |> claim() |> json_response(200)
    {run, body["id"]}
  end

  describe "POST /api/node-jobs/claim" do
    test "200 with the rendered job payload and no worktree path", %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      {run, job} = start_queued_job(board, flow)

      body = conn |> claim() |> json_response(200)

      assert body["id"] == job.id
      assert body["run_id"] == run.id
      assert body["node_id"] == "work"
      assert body["node_type"] == "agent"
      assert body["run"] == "work {ref}"
      assert body["isolation"] == "shared_clean"
      assert body["agent"] == "plan-implementer"
      assert body["vars"]["ref"]
      refute Map.has_key?(body, "worktree")
      refute Map.has_key?(body, "path")

      assert board |> Runs.get_claimed_job(job.id) |> elem(0) == :ok
    end

    test "204 when ?wait=0 and nothing is claimable", %{conn: conn} do
      conn =
        post(
          conn,
          ~p"/api/node-jobs/claim?wait=0",
          Jason.encode!(%{
            "executor" => %{"name" => "idle"},
            "capacity" => %{"shared_clean" => 1}
          })
        )

      assert response(conn, 204)
    end

    test "204 immediately (no long-poll) when the executor advertises zero capacity", %{conn: conn} do
      {micros, conn} =
        :timer.tc(fn ->
          post(
            conn,
            ~p"/api/node-jobs/claim",
            Jason.encode!(%{
              "executor" => %{"name" => "zero-capacity"},
              "capacity" => %{"shared_clean" => 0, "exclusive" => 0}
            })
          )
        end)

      assert response(conn, 204)
      # Well under the 25s long-poll window — proves it short-circuited.
      assert micros < 5_000_000
    end

    test "the long-poll ignores unrelated mailbox messages and still claims on the real run event",
         %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      send(self(), :some_unrelated_message)

      task = Task.async(fn -> Process.sleep(50) && start_queued_job(board, flow) end)

      body = conn |> claim() |> json_response(200)
      Task.await(task)

      assert body["node_id"] == "work"
      assert_received :some_unrelated_message
    end
  end

  describe "POST /api/node-jobs/:id/outcome" do
    setup %{board: board} do
      %{flow: four_outcome_flow(board)}
    end

    test "succeeded routes the run to done", %{conn: conn, board: board, flow: flow} do
      {run, id} = claim_one(conn, board, flow)

      body =
        conn
        |> post(
          ~p"/api/node-jobs/#{id}/outcome",
          Jason.encode!(%{"outcome" => "succeeded", "detail" => "done", "git_sha" => "abc1234"})
        )
        |> json_response(200)

      assert body == %{"status" => "ok", "run_state" => "done"}
      assert Runs.get_run!(run.id).status == :done
    end

    test "failed and partial each complete with 200 and report run_state done", %{conn: conn, board: board, flow: flow} do
      for outcome <- ["failed", "partial"] do
        {run, id} = claim_one(conn, board, flow)

        assert conn
               |> post(~p"/api/node-jobs/#{id}/outcome", Jason.encode!(%{"outcome" => outcome, "detail" => "x"}))
               |> json_response(200) == %{"status" => "ok", "run_state" => "done"}

        assert Runs.get_run!(run.id).status == :done
      end
    end

    test "needs_input parks the run, blocks the card, and reports run_state parked",
         %{conn: conn, board: board, flow: flow} do
      {run, id} = claim_one(conn, board, flow)

      assert conn
             |> post(
               ~p"/api/node-jobs/#{id}/outcome",
               Jason.encode!(%{"outcome" => "needs_input", "detail" => "q?", "session_id" => "s_a41"})
             )
             |> json_response(200) == %{"status" => "ok", "run_state" => "parked"}

      parked = Runs.get_run!(run.id)
      assert parked.status == :parked
      card = Relay.Cards.get_card(board, run.card_id)
      assert card.status == :needs_input
    end

    test "an unknown outcome is rejected 422 and leaves the job claimed", %{conn: conn, board: board, flow: flow} do
      {_run, id} = claim_one(conn, board, flow)

      body =
        conn
        |> post(~p"/api/node-jobs/#{id}/outcome", Jason.encode!(%{"outcome" => "exploded", "detail" => "x"}))
        |> json_response(422)

      assert body["error"]["code"] == "unknown_outcome"
      assert {:ok, _held} = Runs.get_claimed_job(board, id)
    end

    test "reporting on an unheld (reclaimed) job is 409 conflict", %{conn: conn, board: board, flow: flow} do
      {_run, id} = claim_one(conn, board, flow)

      # Simulate reclaim: the job goes back to queued (no longer held).
      Relay.Repo.update_all(
        from(j in Schemas.NodeJob, where: j.id == ^id),
        set: [state: :queued, executor_name: nil]
      )

      body =
        conn
        |> post(~p"/api/node-jobs/#{id}/outcome", Jason.encode!(%{"outcome" => "succeeded", "detail" => "x"}))
        |> json_response(409)

      assert body["error"]["code"] == "conflict"
    end

    test "an unknown job id is 404", %{conn: conn} do
      assert conn
             |> post(~p"/api/node-jobs/999999/outcome", Jason.encode!(%{"outcome" => "succeeded"}))
             |> json_response(404)
    end

    test "a non-numeric job id is 404, not a 500", %{conn: conn} do
      assert conn
             |> post(~p"/api/node-jobs/abc/outcome", Jason.encode!(%{"outcome" => "succeeded"}))
             |> json_response(404)
    end
  end

  describe "POST /api/node-jobs/heartbeat (RLY-164)" do
    test "advertises the executor's CONFIGURED capacity into the scheduler's store", %{conn: conn, board: board} do
      # Before this route existed, Capacity was fed only by /api/board/heartbeat, which
      # `relay execute` never calls — so starting an executor and enabling a flow dispatched
      # nothing at all, and the first live cutover needed a hand-run curl.
      Capacity.reset()

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "executor" => %{"name" => "exec-a", "host" => "box"},
          "capacity" => %{"shared_clean" => 3, "exclusive" => 1},
          "running" => []
        })

      assert %{"revoked" => []} = json_response(conn, 200)

      executor = Relay.Repo.get_by!(Schemas.Executor, board_id: board.id, name: "exec-a")
      assert Capacity.snapshot()[executor.id] == %{shared_clean: 3, exclusive: 1}
    end

    test "a job the executor still holds is NOT revoked", %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      {:ok, executor} = Runs.upsert_executor(board, %{"name" => "exec-a", "capacity" => %{"shared_clean" => 1}})
      {:ok, claimed} = Runs.claim_next_job(executor)

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "executor" => %{"name" => "exec-a"},
          "capacity" => %{"shared_clean" => 1},
          "running" => [claimed.id]
        })

      assert %{"revoked" => []} = json_response(conn, 200)
      assert Runs.get_run!(run.id).status == :running
    end

    test "a job revoked server-side comes back in the response so the executor can kill it",
         %{conn: conn, board: board} do
      # This is what makes the baton (ADR 0004) and the run panel's cancel actually stop an
      # agent. Without it the executor only learns on its next outcome POST — 20+ minutes for
      # a Code implement/smoke node.
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      {:ok, executor} = Runs.upsert_executor(board, %{"name" => "exec-a", "capacity" => %{"shared_clean" => 1}})
      {:ok, claimed} = Runs.claim_next_job(executor)

      # A human takes the baton: the run parks and its live jobs are revoked.
      :ok = Runs.revoke_active_jobs(run)

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "executor" => %{"name" => "exec-a"},
          "capacity" => %{"shared_clean" => 1},
          "running" => [claimed.id]
        })

      assert %{"revoked" => revoked} = json_response(conn, 200)
      assert claimed.id in revoked
    end

    test "never reports another board's job as revoked", %{conn: conn} do
      {:ok, other} = Relay.Boards.create_board(insert(:user), %{name: "Other Board"})
      flow = four_outcome_flow(other)
      {_run, job} = start_queued_job(other, flow)

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "executor" => %{"name" => "exec-a"},
          "capacity" => %{"shared_clean" => 1},
          "running" => [job.id]
        })

      # The id is unknown on THIS board; a cross-board leak would let one board's executor be
      # told to kill another's work.
      assert %{"revoked" => []} = json_response(conn, 200)
    end
  end
end
