defmodule RelayWeb.Api.NodeJobControllerTest do
  use RelayWeb.ConnCase, async: true

  import Ecto.Query

  alias Relay.Runs
  alias Relay.Runs.Capacity
  alias Relay.Runs.FakeDispatcher

  setup %{conn: conn} do
    FakeDispatcher.register(self())
    start_engine!()

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

  # The Code shape: one exclusive node, so a claim exercises the exclusive capacity path.
  defp exclusive_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    plan = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "excl",
        isolation: :exclusive,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: plan.id,
        nodes: [%{key: "work", type: :shell, run: "mix precommit"}],
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

  defp claim(conn, capacity \\ %{"shared_clean" => 1, "exclusive" => 1}, running \\ []) do
    post(
      conn,
      ~p"/api/node-jobs/claim",
      Jason.encode!(%{
        "runner" => %{
          "name" => "fake",
          "host" => "fake",
          "interval" => 30,
          "version" => Runs.min_talk_runner_version()
        },
        "capacity" => capacity,
        "running" => running
      })
    )
  end

  defp blocked_execution(run) do
    Relay.Repo.one!(from e in Schemas.NodeExecution, where: e.run_id == ^run.id and e.outcome == :blocked)
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
            "runner" => %{"name" => "idle", "version" => Runs.min_talk_runner_version()},
            "capacity" => %{"shared_clean" => 1}
          })
        )

      assert response(conn, 204)
    end

    test "204 immediately (no long-poll) when the runner advertises zero capacity", %{conn: conn} do
      {micros, conn} =
        :timer.tc(fn ->
          post(
            conn,
            ~p"/api/node-jobs/claim",
            Jason.encode!(%{
              "runner" => %{"name" => "zero-capacity", "version" => Runs.min_talk_runner_version()},
              "capacity" => %{"shared_clean" => 0, "exclusive" => 0}
            })
          )
        end)

      assert response(conn, 204)
      # Well under the 25s long-poll window — proves it short-circuited.
      assert micros < 5_000_000
    end

    test "a human-requested release rides release_held with a remove disposition (RE337)",
         %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      ref = Relay.Cards.ref(board, Relay.Repo.get!(Schemas.Card, run.card_id))

      beat = %{
        "runner" => %{"name" => "exec-a"},
        "capacity" => %{"exclusive" => 1},
        "running" => [],
        "held" => [%{"ref" => ref, "state" => "bound"}]
      }

      conn |> post(~p"/api/node-jobs/heartbeat", beat) |> json_response(200)
      assert {:ok, :requested} = Runs.request_worktree_release(board, "exec-a", ref)

      assert %{"release_held" => release_held} =
               conn |> post(~p"/api/node-jobs/heartbeat", beat) |> json_response(200)

      # The run is still active — only the request put it here, and `cancelled` makes the runner
      # REMOVE the tree (`failed` would retain it).
      assert release_held == [%{"ref" => ref, "status" => "cancelled"}]
    end

    test "a requested ref reported running is dropped from release_held and the request cleared",
         %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      ref = Relay.Cards.ref(board, Relay.Repo.get!(Schemas.Card, run.card_id))

      bound = %{
        "runner" => %{"name" => "exec-a"},
        "capacity" => %{"exclusive" => 1},
        "running" => [],
        "held" => [%{"ref" => ref, "state" => "bound"}]
      }

      conn |> post(~p"/api/node-jobs/heartbeat", bound) |> json_response(200)
      {:ok, :requested} = Runs.request_worktree_release(board, "exec-a", ref)

      running = put_in(bound, ["held"], [%{"ref" => ref, "state" => "running"}])

      assert %{"release_held" => []} =
               conn |> post(~p"/api/node-jobs/heartbeat", running) |> json_response(200)

      assert %Schemas.Runner{release_requests: []} =
               Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "exec-a")
    end

    test "a non-map runner is a 422, not a 500", %{conn: conn} do
      # RLY-162: Map.put/3 on a string raised BadMapError → 500 + a stack trace, so a
      # slightly-wrong client looked like a server outage on the runner's front door.
      body =
        conn
        |> post(
          ~p"/api/node-jobs/claim",
          Jason.encode!(%{
            "runner" => "not-a-map",
            "capacity" => %{"shared_clean" => 1}
          })
        )
        |> json_response(422)

      assert body["error"]["code"] == "invalid_runner"
      assert body["error"]["message"] =~ "runner"
    end

    test "an absent runner still renders the changeset 400, not the 422", %{conn: conn} do
      # Behavior held constant: absent defaults to %{}, the Runner changeset rejects the
      # blank name, and the fallback's existing `invalid` 400 answers.
      body =
        conn
        |> post(~p"/api/node-jobs/claim", Jason.encode!(%{"capacity" => %{"shared_clean" => 1}}))
        |> json_response(400)

      assert body["error"]["code"] == "invalid"
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

    test "409 runner_outdated when the runner reports no version", %{conn: conn, board: board} do
      # The load-bearing half of RLY-184: claim is the only call that hands out work, so an
      # outdated runner cannot get a job even if every other check is missed. A version-less
      # runner is running pre-RLY-184 code by definition.
      flow = four_outcome_flow(board)
      start_queued_job(board, flow)

      body =
        conn
        |> post(
          ~p"/api/node-jobs/claim",
          Jason.encode!(%{
            "runner" => %{"name" => "ancient", "host" => "old"},
            "capacity" => %{"shared_clean" => 1}
          })
        )
        |> json_response(409)

      assert body["error"]["code"] == "runner_outdated"
      assert body["error"]["required"] == Runs.min_runner_version()
      assert body["error"]["running"] == nil
      assert body["error"]["message"] =~ "restart"
    end

    test "a current runner still claims normally", %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      start_queued_job(board, flow)

      body = conn |> claim() |> json_response(200)

      assert body["id"]
    end

    # RE268 whole-branch review — claiming a TALK job is what moves its turn `:queued → :claimed`.
    # Without this the status was documented but unreachable, and a turn read `:queued` for the
    # whole time `claude -p` was running.
    test "claiming a talk job marks its turn :claimed", %{conn: conn, board: board} do
      stage = Enum.find(board.stages, &(&1.name == "Next up"))
      {:ok, card} = Relay.Cards.create_card(stage, %{title: "Talk card"})
      {:ok, turn} = Relay.Talk.post_message(card, insert(:user), "why is this stuck?")

      body = conn |> claim() |> json_response(200)

      assert body["kind"] == "talk"
      assert body["turn_id"] == turn.id
      assert Relay.Talk.get_turn(turn.id).status == :claimed
    end

    test "a claim never writes the runner's capacity column", %{conn: conn, board: board} do
      # The incident's Bug 1: the claim wrote the FREE count and the heartbeat wrote the
      # CONFIGURED total into one column, so `relay runners` and the runners page read
      # whichever landed last.
      post(conn, ~p"/api/node-jobs/heartbeat", %{
        "runner" => %{"name" => "fake", "host" => "fake", "interval" => 30},
        "capacity" => %{"shared_clean" => 3, "exclusive" => 2},
        "running" => []
      })

      claim(conn, %{"shared_clean" => 0, "exclusive" => 0})

      runner = Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "fake")
      assert runner.capacity == %{"shared_clean" => 3, "exclusive" => 2}
    end

    test "a claim carrying held never writes the runner's held column", %{conn: conn, board: board} do
      # The single-writer thesis (RE311): `runner_attrs/1` never puts "held" on a claim's
      # upsert attrs, only `heartbeat_attrs/2` does — this is the request-shaped proof of it,
      # not just a reading of the controller source.
      post(
        conn,
        ~p"/api/node-jobs/claim",
        Jason.encode!(%{
          "runner" => %{
            "name" => "fake",
            "host" => "fake",
            "interval" => 30,
            "version" => Runs.min_talk_runner_version()
          },
          "capacity" => %{"shared_clean" => 1, "exclusive" => 1},
          "running" => [],
          "held" => [%{"ref" => "RLY-9", "state" => "bound"}],
          "wait" => "0"
        })
      )

      runner = Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "fake")
      assert runner.held == []
    end

    test "RE320: a claim carrying a null rate_limit never un-pauses the stored roster row",
         %{conn: conn, board: board} do
      post(conn, ~p"/api/node-jobs/heartbeat", %{
        "runner" => %{"name" => "fake", "host" => "fake", "interval" => 30},
        "capacity" => %{"shared_clean" => 1},
        "running" => [],
        "rate_limit" => %{
          "window" => "five_hour",
          "utilization" => 0.95,
          "max" => 0.9,
          "resets_at" => 4_102_444_800,
          "reason" => "limit"
        }
      })

      post(
        conn,
        ~p"/api/node-jobs/claim",
        Jason.encode!(%{
          "runner" => %{
            "name" => "fake",
            "host" => "fake",
            "interval" => 30,
            "version" => Runs.min_talk_runner_version(),
            "rate_limit" => nil
          },
          "capacity" => %{"shared_clean" => 1, "exclusive" => 1},
          "running" => [],
          "wait" => "0"
        })
      )

      assert %Schemas.RunnerRateLimit{} =
               Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "fake").rate_limit
    end

    test "RE320: a claim carrying a garbage rate_limit shape never 500s and never touches the roster row",
         %{conn: conn, board: board} do
      post(conn, ~p"/api/node-jobs/heartbeat", %{
        "runner" => %{"name" => "fake", "host" => "fake", "interval" => 30},
        "capacity" => %{"shared_clean" => 1},
        "running" => [],
        "rate_limit" => %{
          "window" => "five_hour",
          "utilization" => 0.95,
          "max" => 0.9,
          "resets_at" => 4_102_444_800,
          "reason" => "limit"
        }
      })

      conn =
        post(
          conn,
          ~p"/api/node-jobs/claim",
          Jason.encode!(%{
            "runner" => %{
              "name" => "fake",
              "host" => "fake",
              "interval" => 30,
              "version" => Runs.min_talk_runner_version(),
              "rate_limit" => %{"window" => "five_hour"}
            },
            "capacity" => %{"shared_clean" => 1, "exclusive" => 1},
            "running" => [],
            "wait" => "0"
          })
        )

      refute conn.status == 500

      assert %Schemas.RunnerRateLimit{} =
               Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "fake").rate_limit
    end

    test "a held ref makes an unpinned exclusive job claimable at zero free capacity",
         %{conn: conn, board: board} do
      flow = exclusive_flow(board)
      {run, _job} = start_queued_job(board, flow)
      card = Relay.Repo.get!(Schemas.Card, run.card_id)
      ref = Relay.Cards.ref(board, card)

      body =
        conn
        |> post(
          ~p"/api/node-jobs/claim",
          Jason.encode!(%{
            "runner" => %{
              "name" => "fake",
              "host" => "fake",
              "interval" => 30,
              "version" => Runs.min_talk_runner_version()
            },
            "capacity" => %{"shared_clean" => 0, "exclusive" => 0},
            "running" => [],
            "held" => [%{"ref" => ref, "state" => "bound"}],
            "wait" => "0"
          })
        )
        |> json_response(200)

      assert body["ref"] == ref
      assert body["isolation"] == "exclusive"
    end
  end

  describe "POST /api/node-jobs/claim — revocations (RE268)" do
    # `wait: 0` keeps the test out of the 25s long-poll; the revocation path is identical, and
    # `wait_loop/5` re-checks on every wake so a Stop mid-poll returns just as promptly.
    defp claim_now(conn, running) do
      post(
        conn,
        ~p"/api/node-jobs/claim",
        Jason.encode!(%{
          "runner" => %{
            "name" => "fake",
            "host" => "fake",
            "interval" => 30,
            "version" => Runs.min_talk_runner_version()
          },
          "capacity" => %{"shared_clean" => 1, "exclusive" => 1},
          "running" => running,
          "wait" => "0"
        })
      )
    end

    test "a no-job claim carries the revoked ids among what the runner reports running", ctx do
      %{conn: conn, board: board} = ctx
      flow = four_outcome_flow(board)
      {run, job} = start_queued_job(board, flow)

      conn |> claim() |> json_response(200)
      Runs.revoke_active_jobs(run)

      body = conn |> claim_now([job.id]) |> json_response(200)

      # This is what makes Stop land in well under a second: without it the runner would not
      # learn the job was killed until its next 15s heartbeat, and `claude` would keep streaming.
      assert body["revoked"] == [job.id]
      refute Map.has_key?(body, "id")
    end

    test "still 204 when nothing this runner reports running has been revoked", ctx do
      assert ctx.conn |> claim_now([]) |> response(204)
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
        set: [state: :queued, runner_name: nil]
      )

      body =
        conn
        |> post(~p"/api/node-jobs/#{id}/outcome", Jason.encode!(%{"outcome" => "succeeded", "detail" => "x"}))
        |> json_response(409)

      assert body["error"]["code"] == "conflict"
    end

    test "a duplicate outcome for a finalized job is first-writer-wins (200, original stands)",
         %{conn: conn, board: board, flow: flow} do
      {_run, id} = claim_one(conn, board, flow)

      # First outcome finalizes the job (:done) and advances the run.
      assert conn
             |> post(~p"/api/node-jobs/#{id}/outcome", Jason.encode!(%{"outcome" => "succeeded", "detail" => "ok"}))
             |> json_response(200) == %{"status" => "ok", "run_state" => "done"}

      # A stray resend with a DIFFERENT payload (the crash-handler's "failed") for the now-:done
      # job gets a clean 200 with the recorded run_state — and does NOT overwrite the record.
      assert conn
             |> post(
               ~p"/api/node-jobs/#{id}/outcome",
               Jason.encode!(%{"outcome" => "failed", "detail" => "stray crash resend"})
             )
             |> json_response(200) == %{"status" => "ok", "run_state" => "done"}

      job = Relay.Repo.get!(Schemas.NodeJob, id)
      execution = Relay.Repo.get!(Schemas.NodeExecution, job.node_execution_id)
      assert execution.outcome == :succeeded
      assert execution.detail == "ok"
    end

    test "reporting on a revoked (zombie) job is 409 conflict", %{conn: conn, board: board, flow: flow} do
      {_run, id} = claim_one(conn, board, flow)

      Relay.Repo.update_all(
        from(j in Schemas.NodeJob, where: j.id == ^id),
        set: [state: :revoked]
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

    test "RE267: resume_at is stored on a blocked outcome, and the node is requeued", %{
      conn: conn,
      board: board,
      flow: flow
    } do
      {run, id} = claim_one(conn, board, flow)

      body =
        conn
        |> post(
          ~p"/api/node-jobs/#{id}/outcome",
          Jason.encode!(%{
            "outcome" => "blocked",
            "detail" => "agent could not run: usage limit",
            "resume_at" => "2100-01-01T00:00:00Z"
          })
        )
        |> json_response(200)

      assert body["run_state"] == "running"
      assert blocked_execution(run).resume_at == ~U[2100-01-01 00:00:00Z]
    end

    test "RE267: resume_at is ignored on any outcome but blocked", %{conn: conn, board: board, flow: flow} do
      {run, id} = claim_one(conn, board, flow)

      conn
      |> post(
        ~p"/api/node-jobs/#{id}/outcome",
        Jason.encode!(%{"outcome" => "failed", "detail" => "x", "resume_at" => "2100-01-01T00:00:00Z"})
      )
      |> json_response(200)

      execution = Relay.Repo.one!(from e in Schemas.NodeExecution, where: e.run_id == ^run.id)
      assert execution.resume_at == nil
    end

    test "RE267: an unparseable resume_at becomes nil and the blocked outcome still parks", %{
      conn: conn,
      board: board,
      flow: flow
    } do
      {run, id} = claim_one(conn, board, flow)

      body =
        conn
        |> post(
          ~p"/api/node-jobs/#{id}/outcome",
          Jason.encode!(%{"outcome" => "blocked", "detail" => "agent could not run: x", "resume_at" => "soon-ish"})
        )
        |> json_response(200)

      assert body["run_state"] == "parked"
      assert blocked_execution(run).resume_at == nil
    end
  end

  describe "POST /api/node-jobs/heartbeat (RLY-164)" do
    test "advertises the runner's CONFIGURED capacity into the scheduler's store", %{conn: conn, board: board} do
      # Before this route existed, Capacity was fed only by /api/board/heartbeat, which
      # `relay start` never calls — so starting a runner and enabling a flow dispatched
      # nothing at all, and the first live cutover needed a hand-run curl.

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "runner" => %{"name" => "exec-a", "host" => "box"},
          "capacity" => %{"shared_clean" => 3, "exclusive" => 1},
          "running" => []
        })

      assert %{"revoked" => []} = json_response(conn, 200)

      runner = Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "exec-a")
      assert Capacity.snapshot()[runner.id] == %{shared_clean: 3, exclusive: 1}
    end

    test "a beat with an unknown class and a garbage value degrades instead of 500ing",
         %{conn: conn, board: board} do
      # RLY-201: atomize_capacity/1 called String.to_existing_atom/1 on client keys, so
      # {"gpu": 1} raised ArgumentError → 500 on the runner's liveness path.

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "runner" => %{"name" => "exec-junk", "host" => "box"},
          "capacity" => %{"gpu" => 1, "shared_clean" => "lots", "exclusive" => 2},
          "running" => []
        })

      assert %{"revoked" => []} = json_response(conn, 200)

      runner = Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "exec-junk")
      assert Capacity.snapshot()[runner.id] == %{shared_clean: 0, exclusive: 2}
      assert runner.capacity == %{"shared_clean" => 0, "exclusive" => 2}
    end

    test "a job the runner still holds is NOT revoked", %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      {:ok, runner} = Runs.upsert_runner(board, %{"name" => "exec-a", "capacity" => %{"shared_clean" => 1}})
      {:ok, claimed} = Runs.claim_next_job(runner)

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "runner" => %{"name" => "exec-a"},
          "capacity" => %{"shared_clean" => 1},
          "running" => [claimed.id]
        })

      assert %{"revoked" => []} = json_response(conn, 200)
      assert Runs.get_run!(run.id).status == :running
    end

    test "a job revoked server-side comes back in the response so the runner can kill it",
         %{conn: conn, board: board} do
      # This is what makes the baton (ADR 0004) and the run panel's cancel actually stop an
      # agent. Without it the runner only learns on its next outcome POST — 20+ minutes for
      # a Code implement/smoke node.
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      {:ok, runner} = Runs.upsert_runner(board, %{"name" => "exec-a", "capacity" => %{"shared_clean" => 1}})
      {:ok, claimed} = Runs.claim_next_job(runner)

      # A human takes the baton: the run parks and its live jobs are revoked.
      :ok = Runs.revoke_active_jobs(run)

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "runner" => %{"name" => "exec-a"},
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
          "runner" => %{"name" => "exec-a"},
          "capacity" => %{"shared_clean" => 1},
          "running" => [job.id]
        })

      # The id is unknown on THIS board; a cross-board leak would let one board's runner be
      # told to kill another's work.
      assert %{"revoked" => []} = json_response(conn, 200)
    end

    test "a cancelled held ref comes back in release_held so the runner frees its slot",
         %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      {:ok, _} = Runs.cancel_run(run)
      ref = Relay.Cards.ref(board, Relay.Repo.get!(Schemas.Card, run.card_id))

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "runner" => %{"name" => "exec-a"},
          "capacity" => %{"exclusive" => 1},
          "running" => [],
          "held" => [%{"ref" => ref, "state" => "bound"}]
        })

      assert %{"release_held" => release_held} = json_response(conn, 200)
      assert %{"ref" => ref, "status" => "cancelled"} in release_held
    end

    test "a still-active held ref is NOT in release_held", %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      ref = Relay.Cards.ref(board, Relay.Repo.get!(Schemas.Card, run.card_id))

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "runner" => %{"name" => "exec-a"},
          "capacity" => %{"exclusive" => 1},
          "running" => [],
          "held" => [%{"ref" => ref, "state" => "bound"}]
        })

      assert %{"release_held" => []} = json_response(conn, 200)
    end

    test "never reports another board's ref in release_held", %{conn: conn} do
      {:ok, other} = Relay.Boards.create_board(insert(:user), %{name: "Other Board 2"})
      flow = four_outcome_flow(other)
      {run, _job} = start_queued_job(other, flow)
      {:ok, _} = Runs.cancel_run(run)
      ref = Relay.Cards.ref(other, Relay.Repo.get!(Schemas.Card, run.card_id))

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "runner" => %{"name" => "exec-a"},
          "capacity" => %{"exclusive" => 1},
          "running" => [],
          "held" => [%{"ref" => ref, "state" => "bound"}]
        })

      assert %{"release_held" => []} = json_response(conn, 200)
    end

    test "a non-map runner is a 422, not a 500", %{conn: conn} do
      # `relay start` beats every ~30s, so leaving heartbeat unfixed would rediscover
      # RLY-162 twelve times an hour.
      body =
        conn
        |> post(
          ~p"/api/node-jobs/heartbeat",
          Jason.encode!(%{
            "runner" => "not-a-map",
            "capacity" => %{"shared_clean" => 1},
            "running" => []
          })
        )
        |> json_response(422)

      assert body["error"]["code"] == "invalid_runner"
      assert body["error"]["message"] =~ "runner"
    end

    test "the beat still succeeds for an outdated runner and tells it so", %{conn: conn} do
      # The beat is how a refused runner stays visible on the roster and how revokes still
      # reach it — refusing it here would make it vanish, which is the opposite of the point.
      body =
        conn
        |> post(
          ~p"/api/node-jobs/heartbeat",
          Jason.encode!(%{
            "runner" => %{"name" => "ancient", "host" => "old"},
            "capacity" => %{"shared_clean" => 1},
            "running" => []
          })
        )
        |> json_response(200)

      assert body["runner_outdated"] == true
      assert body["required_version"] == Runs.min_runner_version()
      assert body["revoked"] == []
    end

    test "a current runner's beat reports it is not outdated", %{conn: conn} do
      body =
        conn
        |> post(
          ~p"/api/node-jobs/heartbeat",
          Jason.encode!(%{
            "runner" => %{"name" => "current", "host" => "new", "version" => Runs.min_talk_runner_version()},
            "capacity" => %{"shared_clean" => 1},
            "running" => []
          })
        )
        |> json_response(200)

      assert body["runner_outdated"] == false
    end

    test "the beat names the newest fetchable runner version (RE185)", %{conn: conn} do
      # The floor (`required_version`) and the target (`latest_runner_version`) are different
      # numbers answering different questions; a runner auto-updates against the target.
      body =
        conn
        |> post(
          ~p"/api/node-jobs/heartbeat",
          Jason.encode!(%{
            "runner" => %{"name" => "box", "host" => "h", "version" => Runs.min_talk_runner_version()},
            "capacity" => %{"shared_clean" => 1},
            "running" => []
          })
        )
        |> json_response(200)

      assert Map.has_key?(body, "latest_runner_version")
      assert body["latest_runner_version"] == Runs.latest_runner_version()
    end

    test "a beat listing a running job refreshes that card's liveness", %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      {:ok, runner} = Runs.upsert_runner(board, %{"name" => "exec-a", "capacity" => %{"shared_clean" => 1}})
      {:ok, claimed} = Runs.claim_next_job(runner)

      card_before = Relay.Repo.get!(Schemas.Card, run.card_id)
      assert card_before.agent_heartbeat_at == nil

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "runner" => %{"name" => "exec-a"},
          "capacity" => %{"shared_clean" => 1},
          "running" => [claimed.id]
        })

      # Reply shape is unchanged by this feature.
      assert %{"revoked" => []} = json_response(conn, 200)
      assert %DateTime{} = Relay.Repo.get!(Schemas.Card, run.card_id).agent_heartbeat_at
    end

    test "a beat that omits a running job does not refresh that card's liveness", %{conn: conn, board: board} do
      flow = four_outcome_flow(board)
      {run, _job} = start_queued_job(board, flow)
      {:ok, runner} = Runs.upsert_runner(board, %{"name" => "exec-a", "capacity" => %{"shared_clean" => 1}})
      {:ok, _claimed} = Runs.claim_next_job(runner)

      conn =
        post(conn, ~p"/api/node-jobs/heartbeat", %{
          "runner" => %{"name" => "exec-a"},
          "capacity" => %{"shared_clean" => 1},
          "running" => []
        })

      assert %{"revoked" => []} = json_response(conn, 200)
      assert Relay.Repo.get!(Schemas.Card, run.card_id).agent_heartbeat_at == nil
    end

    @rate_limit_wire %{
      "window" => "five_hour",
      "utilization" => 0.95,
      "max" => 0.9,
      "resets_at" => 4_102_444_800,
      "reason" => "limit"
    }

    defp beat_rate_limit(conn, name, extra) do
      post(
        conn,
        ~p"/api/node-jobs/heartbeat",
        Map.merge(%{"runner" => %{"name" => name}, "capacity" => %{"shared_clean" => 1}, "running" => []}, extra)
      )
    end

    test "RE320: stores the beat's rate_limit, and a null rate_limit clears it", %{conn: conn, board: board} do
      assert %{"revoked" => []} =
               conn |> beat_rate_limit("exec-rl", %{"rate_limit" => @rate_limit_wire}) |> json_response(200)

      runner = Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "exec-rl")

      assert %Schemas.RunnerRateLimit{
               window: "five_hour",
               utilization: 0.95,
               max: 0.9,
               reason: "limit",
               resets_at: ~U[2100-01-01 00:00:00Z]
             } = runner.rate_limit

      conn |> beat_rate_limit("exec-rl", %{"rate_limit" => nil}) |> json_response(200)

      assert Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "exec-rl").rate_limit == nil
    end

    test "RE320: a beat from an older runner (no rate_limit key) stores nil", %{conn: conn, board: board} do
      conn |> beat_rate_limit("exec-old", %{}) |> json_response(200)

      assert Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "exec-old").rate_limit == nil
    end

    test "RE320: a claim never touches the stored rate_limit", %{conn: conn, board: board} do
      conn |> beat_rate_limit("exec-rl", %{"rate_limit" => @rate_limit_wire}) |> json_response(200)

      {:ok, _runner} = Runs.upsert_runner(board, %{"name" => "exec-rl", "capacity" => %{"shared_clean" => 1}})

      assert %Schemas.RunnerRateLimit{} =
               Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "exec-rl").rate_limit
    end

    test "RE320: an unrecognised rate_limit degrades to nil and is logged, never a 4xx/500", %{conn: conn, board: board} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn
          |> beat_rate_limit("exec-junk-rl", %{"rate_limit" => %{@rate_limit_wire | "window" => "one_hour"}})
          |> json_response(200)
        end)

      assert log =~ "rate_limit"
      assert Relay.Repo.get_by!(Schemas.Runner, board_id: board.id, name: "exec-junk-rl").rate_limit == nil
    end
  end
end
