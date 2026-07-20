defmodule RelayWeb.Api.ExecutorJSON do
  @moduledoc """
  Serializes `Relay.Runs.list_executor_status/2`.

  `capacity` is the **advertised/configured** per-class slot count — the same number the
  heartbeat sends, not a live free count. That distinction is documented at
  `board_controller.ex:56` and is deliberately not re-litigated here; `jobs` is what tells
  you what is actually in flight.

  `stale?` is a `freshness != :fresh` convenience flag, so it is true for both `:stale`
  (missed a beat) and `:gone` (reclaimed — see `Runs.executor_freshness/2`); `freshness`
  is always emitted alongside it, so the two-value/three-value distinction is never lost,
  just collapsed for callers that only want a boolean. `outdated` is orthogonal to both:
  an executor can be perfectly fresh and still be running code below
  `Runs.min_executor_version/0`, in which case the server refuses it work (409
  `executor_outdated`) even though nothing here would flag it as unreachable.
  """

  def index(%{executors: executors}), do: %{data: Enum.map(executors, &executor/1)}

  defp executor(e) do
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
