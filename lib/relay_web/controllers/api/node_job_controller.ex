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

  @outcomes %{
    "succeeded" => :succeeded,
    "failed" => :failed,
    "partial" => :partial,
    "needs_input" => :needs_input
  }

  @doc """
  Claims the next node-job for the advertising executor. Upserts the executor
  (claim doubles as a liveness touch), then atomically claims an eligible job.
  Long-polls up to ~25s on `board:<id>:runs` when nothing is immediately
  claimable; `?wait=0` degrades to short-poll (immediate 204).
  """
  def claim(conn, params) do
    board = conn.assigns.current_board
    exec_attrs = Map.put(Map.get(params, "executor", %{}), "capacity", Map.get(params, "capacity"))

    with {:ok, executor} <- Runs.upsert_executor(board, exec_attrs) do
      case Runs.claim_next_job(executor) do
        {:ok, nil} -> maybe_wait(conn, board, executor, params)
        {:ok, job} -> json(conn, claim_payload(job))
      end
    end
  end

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

  defp parse_outcome(value) do
    case Map.fetch(@outcomes, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :unknown_outcome}
    end
  end

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
