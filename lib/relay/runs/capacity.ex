defmodule Relay.Runs.Capacity do
  @moduledoc """
  The executor-capacity seam (ADR 0006 / RLY-133): a GenServer owning a public
  named ETS table of the **advertised** capacity each connected executor
  carries per isolation class — `%{executor_id => %{shared_clean: n,
  exclusive: n}}`. Like `Relay.BoardWatch`, beats and reads never hop
  through the process, and state is lost on restart by design.

  **Contract: this is the executor's configured per-class slot count, not a
  live free count.** The heartbeat (`RelayWeb.Api.NodeJobController.heartbeat/2`) advertises
  the same total on every beat; it does not decrement as jobs run. In-flight
  `:running` runs are debited server-side, in
  `Relay.Runs.Scheduler.Server.build_snapshot/1`, before the snapshot reaches
  the planner — so a running run holds its slot across reconciles without the
  executor having to re-advertise a decremented count (which would be racy
  across reconciles).

  Global (not board-scoped) within an engine instance: capacity is keyed by executor and read by
  every board's scheduler. The table name is resolved through `Relay.Runs.Instance` — the
  application-wide `default_table/0` in production, a private table per test (ADR 0009), so one
  test's advertised capacity can never be read or wiped by another. The
  `{:executor_capacity_changed, executor_id}` broadcast on `topic/0` stays global: a spurious
  wake-up makes a scheduler re-reconcile against its own (correctly scoped) snapshot, which is
  idempotent. Every `put/2`/`clear/1` broadcasts it so schedulers reconcile immediately
  (acceptance criterion 2's "without waiting a full tick"). The executor heartbeat feeds this
  store; with no executor connected it is empty and the scheduler is dormant.

  **`exclusive` semantics (RLY-231):** the `exclusive` class means the max number of
  concurrent per-card worktrees an executor holds, reinterpreted from the old fixed
  `-work-N` slot count — the per-class debit and the capacity numbers themselves are
  unchanged by that reinterpretation.
  """

  use GenServer

  @default_table :runs_capacity
  @topic "runs:capacity"
  @pubsub Relay.PubSub

  @doc """
  The name of the default (application-wide) capacity ETS table. `Relay.Runs.Instance` uses it as
  the default instance's `:capacity_table`, so the atom is written down exactly once.
  """
  def default_table, do: @default_table

  @doc "Starts the capacity process and creates its ETS table (`:table`, default `default_table/0`)."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The capacity-changed topic."
  def topic, do: @topic

  @doc "Subscribes the calling process to capacity-changed events."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc """
  Sets/replaces `executor_id`'s advertised (configured, not live-free) slots
  and broadcasts the change. Fire-and-forget: `:ok`.

  Takes the **raw** client map — string- or atom-keyed — and shapes it with
  `normalize/1`: unknown classes dropped, bad values zeroed, missing classes 0.
  Callers must not pre-atomize (RLY-201).
  """
  def put(executor_id, slots) when is_map(slots) do
    :ets.insert(table(), {executor_id, normalize(slots)})
    broadcast(executor_id)
    :ok
  end

  @doc "Removes a gone executor and broadcasts the change."
  def clear(executor_id) do
    :ets.delete(table(), executor_id)
    broadcast(executor_id)
    :ok
  end

  @doc "The full capacity map the scheduler reads into `Snapshot.capacity`."
  def snapshot, do: table() |> :ets.tab2list() |> Map.new()

  # The table this process's engine instance owns — `default_table/0` in production, where nothing
  # is registered, and a per-test table under `Relay.DataCase.start_capacity!/0` (ADR 0009). Reads
  # and writes still never hop through the GenServer.
  defp table, do: Relay.Runs.Instance.current().capacity_table

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @doc """
  The single capacity normalizer (RLY-201) — every path that shapes a capacity
  map goes through here, so the closed set of isolation classes is defined
  exactly once.

  Total by construction: any term in, the canonical closed-set map
  `%{shared_clean: n, exclusive: n}` out. Recognises string keys (a
  JSON-decoded heartbeat) and atom keys (in-process callers); every other key
  is **dropped**, and any value that is not a non-negative integer becomes 0.

  Key recognition is a literal pattern match, never `String.to_atom/1` or
  `String.to_existing_atom/1` — the latter is what made an unknown key
  (`{"gpu": 1}`) raise `ArgumentError` and 500 the executor's liveness path.
  Untrusted input degrades, never raises: a stray key from an older or newer
  executor must not knock a working executor off the roster.
  """
  def normalize(slots) when is_map(slots) do
    %{
      shared_clean: non_neg(class(slots, :shared_clean, "shared_clean")),
      exclusive: non_neg(class(slots, :exclusive, "exclusive"))
    }
  end

  def normalize(_slots), do: %{shared_clean: 0, exclusive: 0}

  defp class(slots, atom_key, string_key) do
    case Map.fetch(slots, atom_key) do
      {:ok, n} -> n
      :error -> Map.get(slots, string_key, 0)
    end
  end

  defp non_neg(n) when is_integer(n) and n >= 0, do: n
  defp non_neg(_n), do: 0

  defp broadcast(executor_id) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:executor_capacity_changed, executor_id})
  end
end
