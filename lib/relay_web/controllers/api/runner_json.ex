defmodule RelayWeb.Api.RunnerJSON do
  @moduledoc """
  Serializes `Relay.Runs.list_runner_status/2`.

  `capacity` is the **advertised/configured** per-class slot count — the same number the
  heartbeat sends, not a live free count. That distinction is documented at
  `board_controller.ex:56` and is deliberately not re-litigated here; `jobs` is what tells
  you what is actually in flight.

  `stale?` is a `freshness != :fresh` convenience flag, so it is true for both `:stale`
  (missed a beat) and `:gone` (reclaimed — see `Runs.runner_freshness/2`); `freshness`
  is always emitted alongside it, so the two-value/three-value distinction is never lost,
  just collapsed for callers that only want a boolean. `outdated` is orthogonal to both:
  a runner can be perfectly fresh and still be running code below
  `Runs.min_runner_version/0`, in which case the server refuses it work (409
  `runner_outdated`) even though nothing here would flag it as unreachable.

  `rate_limit` (RE320) is the runner's live Claude usage pause from `Runs.active_rate_limit/2` —
  beating and fresh, but claiming nothing until `resets_at`.
  """

  def index(%{runners: runners}), do: %{data: Enum.map(runners, &runner/1)}

  defp runner(e) do
    %{
      id: e.id,
      name: e.name,
      host: e.host,
      interval: e.interval,
      capacity: Map.new(e.pools, &{&1.name, &1.total}),
      last_heartbeat: e.last_heartbeat,
      freshness: e.freshness,
      stale?: e.freshness != :fresh,
      version: e.version,
      outdated: e.outdated,
      # RE320: the roster's presentation state (`:gone > :stale > :outdated > :rate_limited >
      # :fresh`) and the live usage pause behind `:rate_limited` — nil once it resets.
      display_state: e.display_state,
      rate_limit: e.rate_limit,
      jobs: Enum.map(e.jobs, &job/1)
    }
  end

  defp job(j) do
    %{
      id: j.job_id,
      ref: j.ref,
      title: j.title,
      node_key: j.node_key,
      state: j.state,
      isolation: j.isolation,
      claimed_at: j.claimed_at
    }
  end
end
