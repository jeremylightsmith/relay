defmodule RelayWeb.Api.NodeJobController do
  @moduledoc """
  The server↔executor transport (ADR 0006 card 04): a remote executor claims
  node-jobs (long-poll) and reports their outcomes. Board-key auth, same as the
  rest of `/api`. Pure transport over `Relay.Runs` (W5) — no scheduling or
  dispatch policy lives here.
  """
  use RelayWeb, :controller

  alias Relay.Runs

  action_fallback RelayWeb.Api.FallbackController

  # ~25s sits safely under Fly's proxy idle timeout.
  @long_poll_ms 25_000

  # Every tag `Relay.Runs`/`RunServer` broadcast on `board:<id>:runs` — anything
  # else landing in this request process's mailbox (e.g. a stray monitor `:DOWN`)
  # must fall through rather than be silently swallowed by the long-poll.
  @run_event_tags [:run_started, :node_started, :node_finished, :run_finished, :run_changed, :run_parked, :run_resumed]

  @doc """
  Claims the next node-job for the advertising executor. Upserts the executor
  (claim doubles as a liveness touch), then atomically claims an eligible job.
  Long-polls up to ~25s on `board:<id>:runs` when nothing is immediately
  claimable; `?wait=0` degrades to short-poll (immediate 204).
  """
  def claim(conn, params) do
    board = conn.assigns.current_board

    with {:ok, exec_attrs} <- executor_attrs(params),
         {:ok, executor} <- Runs.upsert_executor(board, exec_attrs) do
      claim_for(conn, board, executor, params)
    end
  end

  defp claim_for(conn, board, executor, params) do
    if Runs.executor_outdated?(executor) do
      refuse_outdated(conn, executor)
    else
      case Runs.claim_next_job(executor) do
        {:ok, nil} -> maybe_wait(conn, board, executor, params)
        {:ok, job} -> json(conn, claim_payload(job))
      end
    end
  end

  @doc """
  The executor's periodic beat (RLY-164): advertises capacity and collects revokes.

  This is the single place an executor announces itself. It does two jobs the pull model
  otherwise has no channel for:

    * **Capacity.** `Relay.Runs.Capacity` is what the scheduler reads to decide whether to
      dispatch at all, and it is deliberately lost on app restart. Before this route existed
      it was fed only by `/api/board/heartbeat`, which `relay execute` never calls — so
      starting an executor and enabling a flow dispatched nothing, and the cutover needed a
      hand-run `curl`. The `capacity` here is the executor's *configured* total, never a live
      free count: `Scheduler.Server.build_snapshot/1` debits in-flight `:running` runs itself,
      so a decremented count would double-debit every running run.

    * **Revokes.** Under the pull model `dispatcher().revoke/1` is a no-op, so taking the
      baton (ADR 0004, via `park_claimed/1`) or cancelling from the run panel could not stop a
      running agent — the executor only found out on its next outcome POST, 20+ minutes for a
      Code `implement` node. The beat reports the jobs it believes it is running; the reply
      names those the server no longer considers live, and the executor kills them.

    * **Capabilities.** The beat may carry `capabilities` — what this executor can resolve
      by name (`%{"agents" => [...], "skills" => [...]}`) — which `Relay.Runs.preflight_flow/1`
      reads to answer "will this flow run here?" before a human enables it. It rides
      send-on-change, not every beat; the reply's `want_capabilities` asks for a resend when
      the server holds none.

    * **Version.** The beat still succeeds for an outdated executor (RLY-184) — it is how that
      process stays visible on the roster and how revokes still reach it. The reply carries
      `executor_outdated` / `required_version` so an executor idling with nothing to claim
      still learns why.

  Board-scoped throughout: an id belonging to another board is simply not live *here*, so one
  board's executor can never be told to kill another's work.
  """
  def heartbeat(conn, params) do
    board = conn.assigns.current_board

    with {:ok, exec_attrs} <- executor_attrs(params),
         {:ok, executor} <- Runs.upsert_executor(board, exec_attrs) do
      running = Map.get(params, "running", [])
      advertise_capacity(executor, Map.get(params, "capacity"))
      # Recover the other direction too (RLY-170): a job this executor still HOLDS but is no
      # longer running — because it restarted and lost its in-process job state — is stranded
      # forever otherwise, invisible to both claim_next_job (queued-only) and the stale-executor
      # reaper (this executor is alive). The absence of a job from `running` is the signal.
      :ok = Runs.requeue_orphaned_jobs(board, executor, running)

      json(conn, %{
        revoked: Runs.revoked_among(board, running),
        # RLY-182: `capabilities` is send-on-change, so an executor that already sent one
        # never sends it again — but the row can lose it (recreated row, or an executor
        # predating this change), which would strand preflight on a permanent false
        # "missing agents" alarm. `upsert_executor/2` returns the post-upsert row, so a
        # beat that DID carry capabilities has already stored them and this reads false.
        want_capabilities: is_nil(executor.capabilities),
        executor_outdated: Runs.executor_outdated?(executor),
        required_version: Runs.min_executor_version()
      })
    end
  end

  # RLY-162: `Map.get/3` returns whatever the client sent, so a non-map `executor` made
  # `Map.put/3` raise BadMapError → a 500 on the executor's front door. Reject the shape
  # here (a request-shape concern) rather than in Runs, which normalizes permissively.
  # RLY-182: `capabilities` rides the same way — optional, and absent on every claim.
  defp executor_attrs(params) do
    case Map.get(params, "executor", %{}) do
      executor when is_map(executor) ->
        {:ok,
         executor
         |> Map.put("capacity", Map.get(params, "capacity"))
         |> Map.put("capabilities", Map.get(params, "capabilities"))}

      _ ->
        {:error, :invalid_executor}
    end
  end

  # RLY-184. Rendered here rather than through FallbackController because the two version
  # numbers are per-request data, not a static string — the executor logs both of them, and a
  # message that cannot name the required version cannot tell anyone what to do about it.
  # 409 (not 403): the request is well-formed, it conflicts with the server's current state.
  defp refuse_outdated(conn, executor) do
    required = Runs.min_executor_version()
    running = executor.version || "none"

    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        code: "executor_outdated",
        required: required,
        running: executor.version,
        message:
          "executor version #{running} is below the required minimum #{required} — " <>
            "restart it to pick up current code"
      }
    })
  end

  # RLY-201: hand the raw client map straight to the domain. Runs.Capacity.put/2
  # normalizes (unknown classes dropped, bad values zeroed) — the controller must not
  # shape capacity itself, and must never atomize request keys.
  defp advertise_capacity(executor, capacity) when is_map(capacity) do
    Runs.Capacity.put(executor.id, capacity)
  end

  defp advertise_capacity(_executor, _capacity), do: :ok

  @doc """
  Reports a node-job outcome, completing the job and waking the engine to route
  it. `outcome` must be in the closed set (else 422 `unknown_outcome`); the job
  must still be held by a live claim (else 409 `conflict`). Replies with the
  run's post-outcome `run_state` (running|parked|done|failed|cancelled) so the
  executor knows whether to keep or free an exclusive worktree slot bound to
  this run (ExecutorPool.release, bin/relay).
  """
  def outcome(conn, %{"id" => id} = params) do
    board = conn.assigns.current_board

    with {:ok, outcome} <- parse_outcome(params["outcome"]),
         {:ok, job} <- Runs.get_claimed_job(board, id),
         {:ok, run} <- report(job, outcome, params) do
      json(conn, %{status: "ok", run_state: Atom.to_string(run.status)})
    end
  end

  defp report(job, outcome, params) do
    attrs = %{
      outcome: outcome,
      detail: params["detail"],
      git_sha: params["git_sha"],
      session_id: params["session_id"]
    }

    case Runs.report_outcome(job, attrs) do
      {:ok, run} -> {:ok, run}
      {:error, :job_not_active} -> {:error, :conflict}
      {:error, other} -> {:error, other}
    end
  end

  # RLY-203: the accepted outcome strings are derived from Schemas.NodeExecution.outcomes/0, so
  # the transport can never name an outcome the domain lacks (or miss one). The set itself is
  # pinned to the enum by the vocabulary exhaustiveness guard.
  defp parse_outcome(value) when is_binary(value) do
    case Enum.find(Schemas.NodeExecution.outcomes(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :unknown_outcome}
      outcome -> {:ok, outcome}
    end
  end

  defp parse_outcome(_value), do: {:error, :unknown_outcome}

  defp maybe_wait(conn, board, executor, params) do
    cond do
      params["wait"] in ["0", 0] ->
        send_resp(conn, 204, "")

      # No advertised capacity → claim_next_job/1 can never succeed for this
      # executor; a full 25s long-poll would be a wasted connection.
      zero_capacity?(executor) ->
        send_resp(conn, 204, "")

      true ->
        Runs.subscribe(board.id)
        wait_loop(conn, executor, System.monotonic_time(:millisecond) + @long_poll_ms)
    end
  end

  defp zero_capacity?(%{capacity: capacity}) do
    Enum.all?(capacity, fn {_class, n} -> not (is_integer(n) and n > 0) end)
  end

  # Retry the atomic claim whenever a run event fires; anything else in the
  # mailbox (e.g. a stray monitor message) falls through and keeps waiting.
  defp wait_loop(conn, executor, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout <= 0 do
      send_resp(conn, 204, "")
    else
      receive do
        run_event when is_tuple(run_event) and elem(run_event, 0) in @run_event_tags ->
          case Runs.claim_next_job(executor) do
            {:ok, nil} -> wait_loop(conn, executor, deadline)
            {:ok, job} -> json(conn, claim_payload(job))
          end
      after
        timeout -> send_resp(conn, 204, "")
      end
    end
  end

  # Never leaks worktree paths — those are executor-local. Serialises the payload
  # W5 stored (raw run + resolved vars); {ref}/{branch} expansion stays executor-side.
  defp claim_payload(job) do
    payload = job.payload

    %{
      id: job.id,
      run_id: job.run_id,
      ref: get_in(payload, ["vars", "ref"]),
      node_id: job.node_key,
      node_type: payload["node_type"],
      agent: payload["agent"],
      run: payload["run"],
      isolation: payload["isolation"],
      resume_session: payload["resume_session"],
      vars: payload["vars"] || %{}
    }
  end
end
