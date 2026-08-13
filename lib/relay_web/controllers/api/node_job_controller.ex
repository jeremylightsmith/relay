defmodule RelayWeb.Api.NodeJobController do
  @moduledoc """
  The server↔executor transport (ADR 0006 card 04): a remote executor claims
  node-jobs (long-poll) and reports their outcomes. Board-key auth, same as the
  rest of `/api`. Pure transport over `Relay.Runs` (W5) — no scheduling or
  dispatch policy lives here.
  """
  use RelayWeb, :controller

  alias Relay.Runs
  alias Relay.Talk

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
        {:ok, job} -> json(conn, granted(job))
      end
    end
  end

  # RE268 — a claim is where a talk turn becomes `:claimed`. It happens here rather than in
  # `Relay.Runs.claim_next_job/1` so the run lifecycle keeps no Talk knowledge: it claims a job,
  # and only `Relay.Talk` knows a job can carry a turn. A refusal (the turn was Stopped in the
  # window before the executor noticed) is not an error the executor can act on — the revoke it
  # collects on its next heartbeat is what ends the work.
  defp granted(%Schemas.NodeJob{kind: :talk} = job) do
    Talk.mark_claimed(job)
    claim_payload(job)
  end

  defp granted(job), do: claim_payload(job)

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
      still learns why. The reply also carries `latest_executor_version` (RE185) — the
      `EXECUTOR_VERSION` of the `bin/relay` this app itself serves at `/api/scaffold` (RE304) —
      which an executor with `auto_update` on uses to update itself.

    * **Liveness (RLY-226).** The same `running` list is a positive signal: each id maps to a
      card, and `Relay.Runs.refresh_running_card_liveness/2` stamps `agent_heartbeat_at` fresh on
      the cards whose job is still active server-side. That is what keeps a live-but-quiet agent —
      one mid-`mix precommit`, a long test, a long thinking turn — from falsely reading `:stale` in
      `Cards.health/1`. It is the exact positive complement of the revoke query above (revoked =
      on-board but NOT active; refresh = on-board AND active), and never masks a real stall: a job
      the server has finalized/revoked is not active, so it is not refreshed, and `health/1` decides
      `:stopped` before staleness regardless.

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

      # RLY-226: the positive complement of `revoked_among/2` in the reply below — stamp
      # `agent_heartbeat_at` fresh on the cards whose reported job is still active, so a
      # quiet-but-running agent does not falsely age to `:stale` in `Cards.health/1`. Result
      # ignored: liveness is best-effort.
      _ = Runs.refresh_running_card_liveness(board, running)

      json(conn, %{
        revoked: Runs.revoked_among(board, running),
        # RLY-218: the run-scoped analogue of `revoked`, one level up — the executor reports
        # the run-ids of exclusive slots it holds with no live job (`bound_runs`), and this
        # names the ones now terminal server-side so it can release those slots too.
        release_runs:
          Enum.map(
            Runs.terminal_among(board, Map.get(params, "bound_runs", [])),
            &%{run_id: &1.id, status: &1.status}
          ),
        # RLY-182: `capabilities` is send-on-change, so an executor that already sent one
        # never sends it again — but the row can lose it (recreated row, or an executor
        # predating this change), which would strand preflight on a permanent false
        # "missing agents" alarm. `upsert_executor/2` returns the post-upsert row, so a
        # beat that DID carry capabilities has already stored them and this reads false.
        want_capabilities: is_nil(executor.capabilities),
        executor_outdated: Runs.executor_outdated?(executor),
        required_version: Runs.min_executor_version(),
        # RE185: the floor above says what is REFUSED; this says what can be FETCHED — the
        # `EXECUTOR_VERSION` of the `bin/relay` this app serves at /api/scaffold (RE304), so it
        # cannot lie. `nil` when the scaffold has not been built, which the executor reads as
        # "never auto-update".
        latest_executor_version: Runs.latest_executor_version()
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
  this run (ExecutorPool.release, bin/relay). `no_changes` (RE310) is the
  node's assertion that its work was already committed; the engine honours it
  only when this node's own history proves it (see `Relay.Runs.RunServer`).
  """
  def outcome(conn, %{"id" => id} = params) do
    board = conn.assigns.current_board

    with {:ok, outcome} <- parse_outcome(params["outcome"]),
         {:ok, run} <- resolve_and_report(board, id, outcome, params) do
      json(conn, %{status: "ok", run_state: Atom.to_string(run.status)})
    end
  end

  # RLY-202: a duplicate outcome POST for an already-finalized (:done) job is first-writer-wins —
  # answer success with the run's recorded state, no re-finalize, no RunServer call. :queued
  # (reassigned) / :revoked (zombie) still 409 via {:error, :conflict}.
  defp resolve_and_report(board, id, outcome, params) do
    case Runs.get_claimed_job(board, id) do
      {:ok, job} -> report(job, outcome, params)
      {:already_finalized, run} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp report(job, outcome, params) do
    attrs = %{
      outcome: outcome,
      detail: params["detail"],
      git_sha: params["git_sha"],
      session_id: params["session_id"],
      # RE310: the agent's assertion that no changes were needed. An executor predating the flag
      # omits the key, which reads false — byte-identical to today's behaviour, which is why
      # `@min_executor_version` is deliberately NOT raised for this change.
      no_changes: params["no_changes"] == true
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
    running = List.wrap(params["running"])

    cond do
      params["wait"] in ["0", 0] ->
        no_work(conn, board, running)

      # No advertised capacity → claim_next_job/1 can never succeed for this
      # executor; a full 25s long-poll would be a wasted connection.
      zero_capacity?(executor) ->
        no_work(conn, board, running)

      true ->
        Runs.subscribe(board.id)
        wait_loop(conn, board, executor, running, System.monotonic_time(:millisecond) + @long_poll_ms)
    end
  end

  # RE268 — a revocation reaching the executor is what actually kills a running `claude -p`, and
  # until now it only rode the 15s heartbeat: pressing Stop left output streaming for up to 15s
  # (measured ~13). The claim long-poll is already open and already woken by run events, so it
  # carries revocations too. `revoked` is the SAME key and the same `Runs.revoked_among/2` source
  # the heartbeat reply uses — the executor applies both through one handler, so there is no
  # second notion of "what is dead".
  #
  # Only the no-job reply carries it. A granted job's payload shape is pinned by the executor
  # contract and left untouched; an executor being handed work is not the case Stop cares about.
  defp no_work(conn, board, running) do
    case Runs.revoked_among(board, running) do
      [] -> send_resp(conn, 204, "")
      revoked -> json(conn, %{revoked: revoked})
    end
  end

  defp zero_capacity?(%{capacity: capacity}) do
    Enum.all?(capacity, fn {_class, n} -> not (is_integer(n) and n > 0) end)
  end

  # Retry the atomic claim whenever a run event fires; anything else in the
  # mailbox (e.g. a stray monitor message) falls through and keeps waiting.
  defp wait_loop(conn, board, executor, running, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout <= 0 do
      no_work(conn, board, running)
    else
      receive do
        run_event when is_tuple(run_event) and elem(run_event, 0) in @run_event_tags ->
          case Runs.claim_next_job(executor) do
            # Woken with nothing to grant is the Stop case: `Talk.stop_turn/1` broadcasts a run
            # event precisely so this loop re-checks. Return as soon as something is revoked,
            # rather than sitting out the rest of the 25s with a kill order in hand.
            {:ok, nil} ->
              case Runs.revoked_among(board, running) do
                [] -> wait_loop(conn, board, executor, running, deadline)
                revoked -> json(conn, %{revoked: revoked})
              end

            {:ok, job} ->
              json(conn, granted(job))
          end
      after
        timeout -> no_work(conn, board, running)
      end
    end
  end

  # Never leaks worktree paths — those are executor-local. `kind` rides on BOTH shapes (RE268):
  # the executor branches on it, and pinning it in the fixture is what makes a rename break CI
  # rather than production.
  defp claim_payload(%Schemas.NodeJob{kind: :talk} = job) do
    payload = job.payload

    %{
      id: job.id,
      kind: "talk",
      ref: payload["ref"],
      turn_id: payload["turn_id"],
      prompt: payload["prompt"],
      author: payload["author"],
      branch: payload["branch"],
      seed: payload["seed"] || %{},
      resume_session: payload["resume_session"]
    }
  end

  # Serialises the payload W5 stored (raw run + resolved vars); {ref}/{branch} expansion stays
  # executor-side.
  defp claim_payload(job) do
    payload = job.payload

    %{
      id: job.id,
      kind: "node",
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
