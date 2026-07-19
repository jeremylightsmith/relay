defmodule Relay.Runs.Preflight do
  @moduledoc """
  "If I turn this flow on, will it work?" — the read-only readiness snapshot behind the Flows
  enable confirm (RLY-182). Enabling a flow is the moment a board starts handing real cards to
  agents, and it was previously done blind: a missing agent file surfaced as an engine-looking
  error on the first agent node, *after* the card had already moved.

  **Readiness is per-executor, never a union.** A run dispatches to ONE executor, so a union
  across machines could report ready when no single machine can actually run the flow. An
  executor is a candidate only when it is `:fresh`, advertises capacity in the flow's own
  isolation class, and resolves every agent and skill the flow names.

  **Unknown is not missing.** A row whose `capabilities` is nil has never reported its
  inventory. It must not be disqualified and its names must never be rendered as missing —
  that is the false alarm this feature exists to avoid. Those executors are surfaced
  separately in `:unreported`.

  **Report, do not block.** Nothing here gates enabling; the caller renders the verdict and
  the CTA stays live in every state.

  Lives in `Relay.Runs`, not `Relay.Flows`: `Flows` owns what a flow REQUIRES
  (`Flows.node_requirements/1`, pure graph parsing) and may not depend on `Runs`, while this
  needs executors and capacity. The reverse edge is a boundary cycle the compiler rejects.

  Read-only and cheap enough for the render path: one executor query plus
  `Relay.Runs.Capacity.snapshot/0` (ETS). It is a SNAPSHOT taken on click — it does not
  subscribe to anything and does not live-update while the banner is open.
  """

  import Ecto.Query

  alias Relay.Flows
  alias Relay.Repo
  alias Relay.Runs
  alias Relay.Runs.Capacity
  alias Schemas.Executor
  alias Schemas.Flow

  @type detail :: %{
          name: String.t(),
          freshness: :fresh | :stale | :gone,
          capacity_ok?: boolean(),
          missing_agents: [String.t()],
          missing_skills: [String.t()],
          reported_capabilities?: boolean()
        }

  @type t :: %{
          ready?: boolean(),
          stages: :ok | {:missing, [:pulls_from | :works_in | :lands_on]},
          requires: %{agents: [String.t()], skills: [String.t()]},
          executors: :none_connected | {:ok, String.t()} | {:no_candidate, [detail()]},
          unreported: [String.t()]
        }

  @doc """
  The readiness snapshot for `flow` at `now` (defaults to the current time; injectable so
  freshness is testable). Writes nothing.
  """
  @spec run(struct(), DateTime.t() | nil) :: t()
  def run(%Flow{} = flow, now \\ nil) do
    now = now || DateTime.truncate(DateTime.utc_now(), :second)
    requires = Flows.node_requirements(flow)
    capacity = Capacity.snapshot()

    details =
      from(e in Executor, where: e.board_id == ^flow.board_id, order_by: [asc: e.name])
      |> Repo.all()
      |> Enum.map(&detail(&1, flow, requires, capacity, now))
      # A `:gone` row means the reaper has already requeued/parked its work (same predicate
      # as `Runs.executor_stale?/2`) — it is not connected, and its stale inventory must not
      # be unioned into "missing" or counted toward "hasn't reported yet".
      |> Enum.reject(&(&1.freshness == :gone))

    stages = stage_check(flow)
    executors = verdict(details)

    %{
      ready?: stages == :ok and match?({:ok, _name}, executors),
      stages: stages,
      requires: requires,
      executors: executors,
      unreported: for(d <- details, not d.reported_capabilities?, do: d.name)
    }
  end

  # Prefer a candidate that has actually reported, so a fully-known-good machine wins over
  # one we merely can't rule out.
  defp verdict([]), do: :none_connected

  defp verdict(details) do
    candidates = Enum.filter(details, & &1.candidate?)

    case Enum.find(candidates, & &1.reported_capabilities?) || List.first(candidates) do
      nil -> {:no_candidate, Enum.map(details, &Map.delete(&1, :candidate?))}
      %{name: name} -> {:ok, name}
    end
  end

  defp detail(%Executor{} = executor, %Flow{} = flow, requires, capacity, now) do
    freshness = Runs.executor_freshness(executor, now)
    reported? = is_map(executor.capabilities)
    capacity_ok? = free_slots(capacity, executor.id, flow.isolation) > 0

    # Unknown ≠ missing: with nothing reported there is nothing to subtract, so the lists
    # stay empty and this executor is not accused of lacking anything.
    missing_agents = missing(reported?, requires.agents, executor.capabilities, "agents")
    missing_skills = missing(reported?, requires.skills, executor.capabilities, "skills")

    %{
      name: executor.name,
      freshness: freshness,
      capacity_ok?: capacity_ok?,
      missing_agents: missing_agents,
      missing_skills: missing_skills,
      reported_capabilities?: reported?,
      candidate?: freshness == :fresh and capacity_ok? and missing_agents == [] and missing_skills == []
    }
  end

  defp missing(false, _required, _capabilities, _key), do: []
  defp missing(true, required, capabilities, key), do: required -- Map.get(capabilities, key, [])

  # Capacity.snapshot/0 is atom-keyed per isolation class and normalizes missing classes to
  # 0. An executor absent from the store has advertised nothing since the last app restart.
  defp free_slots(capacity, executor_id, isolation) do
    capacity |> Map.get(executor_id, %{}) |> Map.get(isolation, 0)
  end

  # The stage FKs are `on_delete: :nilify_all`, so deleting a trigger stage disarms the flow
  # by nilling its id — which is exactly the orphaned-flow case this check exists to catch.
  defp stage_check(%Flow{} = flow) do
    missing =
      for {key, id} <- [
            pulls_from: flow.pulls_from_stage_id,
            works_in: flow.works_in_stage_id,
            lands_on: flow.lands_on_stage_id
          ],
          is_nil(id),
          do: key

    if missing == [], do: :ok, else: {:missing, missing}
  end
end
