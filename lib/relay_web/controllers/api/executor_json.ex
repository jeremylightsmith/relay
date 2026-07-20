defmodule RelayWeb.Api.ExecutorJSON do
  @moduledoc """
  Serializes `Relay.Runs.list_executor_status/2`.

  `capacity` is the **advertised/configured** per-class slot count — the same number the
  heartbeat sends, not a live free count. That distinction is documented at
  `board_controller.ex:56` and is deliberately not re-litigated here; `jobs` is what tells
  you what is actually in flight.
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
