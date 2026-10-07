defmodule Relay.Runs.Capacity do
  @moduledoc """
  The runner-capacity seam (ADR 0006 / RLY-133): a GenServer owning a public
  named ETS table of the **advertised** capacity each connected runner
  carries per isolation class, one row per runner tagged with the runner's
  board — `{runner_id, board_id, %{shared_clean: n, exclusive: n}}`. Like `Relay.BoardWatch`, beats and reads never hop
  through the process, and state is lost on restart by design.

  **Contract: this is the runner's configured per-class slot count, not a
  live free count.** The heartbeat (`RelayWeb.Api.NodeJobController.heartbeat/2`) advertises
  the same total on every beat; it does not decrement as jobs run. In-flight
  `:running` runs are debited server-side, in
  `Relay.Runs.Scheduler.Server.build_snapshot/1`, before the snapshot reaches
  the planner — so a running run holds its slot across reconciles without the
  runner having to re-advertise a decremented count (which would be racy
  across reconciles).

  Entries are keyed by runner and carry the runner's board id (RE402): `snapshot/0` drops the
  board id and returns `%{runner_id => slots}` (each scheduler allow-lists its own runners), while
  `live?/1` answers "does this board have any advertised slot?" from ETS alone. The table name is resolved through `Relay.Runs.Instance` — the
  application-wide `default_table/0` in production, a private table per test (ADR 0009), so one
  test's advertised capacity can never be read or wiped by another. The
  `{:runner_capacity_changed, runner_id}` broadcast on `topic/0` stays global: a spurious
  wake-up makes a scheduler re-reconcile against its own (correctly scoped) snapshot, which is
  idempotent. It fires **only on a real change** — a `put/3` whose row differs from the stored one,
  or a `clear/1` that removed an entry — so schedulers reconcile immediately on a change
  (acceptance criterion 2's "without waiting a full tick") without being woken by every beat. The
  runner heartbeat feeds this store; `Relay.Runs.reclaim_stale_runners/1` (the reaper's sweep)
  evicts every stale runner's entry. With no runner connected it is empty and the scheduler is
  dormant.

  **`exclusive` semantics (RLY-231):** the `exclusive` class means the max number of
  concurrent per-card worktrees a runner holds, reinterpreted from the old fixed
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
  Sets/replaces `runner_id`'s advertised (configured, not live-free) slots on `board_id` — the
  runner's board — and broadcasts **only when the stored entry actually changed**.
  Fire-and-forget: `:ok`.

  Takes the **raw** client map — string- or atom-keyed — and shapes it with
  `normalize/1`: unknown classes dropped, bad values zeroed, missing classes 0.
  Callers must not pre-atomize (RLY-201).
  """
  def put(runner_id, board_id, slots) when is_map(slots) do
    entry = {runner_id, board_id, normalize(slots)}

    # Every heartbeat re-advertises the same configured total, and the topic is global — so an
    # unconditional broadcast woke every board's scheduler on every beat of every runner. Compare
    # the whole stored row (board id included: a runner moving boards is a change) first.
    if :ets.lookup(table(), runner_id) != [entry] do
      :ets.insert(table(), entry)
      broadcast(runner_id)
    end

    :ok
  end

  @doc "Removes a gone runner, broadcasting only when it actually had an entry."
  def clear(runner_id) do
    if :ets.member(table(), runner_id) do
      :ets.delete(table(), runner_id)
      broadcast(runner_id)
    end

    :ok
  end

  @doc """
  True iff some runner advertising on `board_id` has a positive slot in any class. Reads ETS
  only — never the Repo — so a scheduler can ask it every tick for free. No freshness check: a
  dead runner keeps its board live until the reaper's sweep evicts it.
  """
  def live?(board_id) do
    table()
    |> :ets.match_object({:_, board_id, :_})
    |> Enum.any?(fn {_runner_id, _board_id, slots} -> slots.shared_clean > 0 or slots.exclusive > 0 end)
  end

  @doc "The full capacity map the scheduler reads into `Snapshot.capacity` — `%{runner_id => slots}`."
  def snapshot do
    for {runner_id, _board_id, slots} <- :ets.tab2list(table()), into: %{}, do: {runner_id, slots}
  end

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
  (`{"gpu": 1}`) raise `ArgumentError` and 500 the runner's liveness path.
  Untrusted input degrades, never raises: a stray key from an older or newer
  runner must not knock a working runner off the roster.
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

  defp broadcast(runner_id) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:runner_capacity_changed, runner_id})
  end
end
