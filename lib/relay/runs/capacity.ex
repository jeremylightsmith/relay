defmodule Relay.Runs.Capacity do
  @moduledoc """
  The executor-capacity seam (ADR 0006 / RLY-133): a GenServer owning a public
  named ETS table of the **advertised** capacity each connected executor
  carries per isolation class — `%{executor_id => %{shared_clean: n,
  exclusive: n}}`. Mirrors `Relay.RunnerPresence`: beats and reads never hop
  through the process, and state is lost on restart by design.

  **Contract: this is the executor's configured per-class slot count, not a
  live free count.** The heartbeat (`BoardController.heartbeat/2`) advertises
  the same total on every beat; it does not decrement as jobs run. In-flight
  `:running` runs are debited server-side, in
  `Relay.Runs.Scheduler.Server.build_snapshot/1`, before the snapshot reaches
  the planner — so a running run holds its slot across reconciles without the
  executor having to re-advertise a decremented count (which would be racy
  across reconciles).

  Global (not board-scoped): capacity is keyed by executor and read by every
  board's scheduler. Every `put/2`/`clear/1` broadcasts
  `{:executor_capacity_changed, executor_id}` on `topic/0` so schedulers
  reconcile immediately (acceptance criterion 2's "without waiting a full tick").
  W9/W10 feed this store from executor heartbeats; until then it stays empty and
  the scheduler is dormant.
  """

  use GenServer

  @table :runs_capacity
  @topic "runs:capacity"
  @pubsub Relay.PubSub

  @doc "Starts the capacity process and creates its public ETS table."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "The capacity-changed topic."
  def topic, do: @topic

  @doc "Subscribes the calling process to capacity-changed events."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc """
  Sets/replaces `executor_id`'s advertised (configured, not live-free) slots
  (missing classes default to 0, negatives floor to 0) and broadcasts the
  change. Fire-and-forget: `:ok`.
  """
  def put(executor_id, slots) when is_map(slots) do
    :ets.insert(@table, {executor_id, normalize(slots)})
    broadcast(executor_id)
    :ok
  end

  @doc "Removes a gone executor and broadcasts the change."
  def clear(executor_id) do
    :ets.delete(@table, executor_id)
    broadcast(executor_id)
    :ok
  end

  @doc "The full capacity map the scheduler reads into `Snapshot.capacity`."
  def snapshot, do: @table |> :ets.tab2list() |> Map.new()

  @doc "Drops all advertised capacity (used in tests to start from a clean slate)."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  defp normalize(slots) do
    %{
      shared_clean: non_neg(Map.get(slots, :shared_clean, 0)),
      exclusive: non_neg(Map.get(slots, :exclusive, 0))
    }
  end

  defp non_neg(n) when is_integer(n) and n >= 0, do: n
  defp non_neg(_n), do: 0

  defp broadcast(executor_id) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:executor_capacity_changed, executor_id})
  end
end
