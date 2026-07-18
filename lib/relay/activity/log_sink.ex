defmodule Relay.Activity.LogSink do
  @moduledoc """
  The debouncing sink for runner log lines (RLY-112): catches ref-tagged entries
  from `Relay.AgentLog.record/2` and folds a burst into **one** `insert_all` plus
  **one** `{:card_log_appended, card_id, entries}` per card.

  Both bounds matter under the load this exists for:

    * **Debounce** — the first cast arms a 250ms timer; later casts inside the window
      just append. A burst that reaches 500 buffered rows flushes immediately, which
      is what keeps a runaway agent from ballooning the process heap.
    * **One event per card per flush** — `Relay.Events.broadcast/2` calls
      `Relay.BoardWatch.bump/1` on every event, so reusing the per-entry
      `{:timeline_appended, ...}` would bump the board version once *per log line*.
      Worst case here is ~4 events/sec/card instead of hundreds.

  Best-effort by construction, matching the runner's own log path: `enqueue/3` is
  a fire-and-forget cast that never blocks the `POST /api/board/logs` request, and
  if this process crashes the supervisor restarts it and the in-flight buffer is
  lost. Logs are not an audit trail — moves and decisions still go through
  `Relay.Activity.log/2` synchronously.

  Ordering survives the debounce: the buffer is prepended and reversed at flush, so
  rows insert in true chronological order, `inserted_at` carries the entry's stamped
  `ts` (not flush time), and same-second ties break by ascending `id`.

  Resolution of `{board_id, ref} -> card_id` is memoised in state and done with a
  local query on purpose: `Relay.Cards` already deps on `Relay.Activity`, so calling
  `Cards.get_card_by_ref/2` from here would be a boundary cycle.
  """

  use GenServer

  import Ecto.Query

  alias Relay.Events
  alias Relay.Repo

  require Logger

  @debounce_ms 250
  @max_buffer 500

  @doc """
  Starts the sink. `opts[:name]` defaults to `#{inspect(__MODULE__)}`;
  `opts[:debounce_ms]` defaults to `#{@debounce_ms}` (tests pass `0`).
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Hands `entries` — `Relay.AgentLog`-stamped maps, each with a **non-nil `ref`** —
  to `sink` for the board `board_id`. Always `:ok`: a cast never blocks and never
  fails the caller.
  """
  # Multiple clauses + a default argument require a bodiless header.
  def enqueue(board_id, entries, sink \\ __MODULE__)

  def enqueue(_board_id, [], _sink), do: :ok

  def enqueue(board_id, entries, sink) when is_list(entries) do
    GenServer.cast(sink, {:enqueue, board_id, entries})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       buffer: [],
       count: 0,
       refs: %{},
       timer: nil,
       debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms)
     }}
  end

  @impl true
  def handle_cast({:enqueue, board_id, entries}, state) do
    buffer = Enum.reduce(entries, state.buffer, &[{board_id, &1} | &2])
    state = %{state | buffer: buffer, count: state.count + length(entries)}

    if state.count >= @max_buffer do
      {:noreply, flush(state)}
    else
      {:noreply, arm(state)}
    end
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | timer: nil})}

  defp arm(%{timer: nil} = state), do: %{state | timer: Process.send_after(self(), :flush, state.debounce_ms)}
  defp arm(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp flush(%{buffer: []} = state), do: cancel_timer(state)

  defp flush(state) do
    state = cancel_timer(state)
    entries = Enum.reverse(state.buffer)

    # Best-effort by construction (see moduledoc): a DB error must NOT crash the sink.
    # It sits as a :one_for_one sibling of Relay.Repo, so a crash storm on a transient
    # DB blip would trip the supervisor's max_restarts and take the Repo down with it.
    # On failure we drop the in-flight batch (the doc's stated tradeoff) and keep the
    # resolved-ref cache, staying alive for the next window.
    refs =
      try do
        refs = resolve_refs(state.refs, entries)

        resolved =
          Enum.flat_map(entries, fn {board_id, entry} ->
            case Map.get(refs, {board_id, entry.ref}) do
              nil -> []
              card_id -> [{board_id, card_id, entry}]
            end
          end)

        insert_and_broadcast(resolved)
        refs
      rescue
        error ->
          Logger.warning("LogSink dropped #{state.count} buffered log line(s): #{Exception.message(error)}")
          state.refs
      end

    %{state | buffer: [], count: 0, refs: refs}
  end

  defp insert_and_broadcast([]), do: :ok

  defp insert_and_broadcast(resolved) do
    rows = Enum.map(resolved, fn {_board_id, card_id, entry} -> row(card_id, entry) end)
    {_count, inserted} = Repo.insert_all(Schemas.Activity, rows, returning: true)

    boards = Map.new(resolved, fn {board_id, card_id, _entry} -> {card_id, board_id} end)

    inserted
    # insert_all returns structs with :user unloaded; these rows are always the
    # agent, so pin it to nil rather than leave a NotLoaded landmine in the payload.
    |> Enum.map(&%{&1 | user: nil})
    |> Enum.group_by(& &1.card_id)
    |> Enum.each(fn {card_id, card_rows} ->
      Events.broadcast(Map.fetch!(boards, card_id), {:card_log_appended, card_id, card_rows})
    end)
  end

  defp row(card_id, entry) do
    ts = DateTime.truncate(entry.ts, :second)

    %{
      card_id: card_id,
      type: type_for(entry.kind),
      meta: %{},
      actor_type: :agent,
      user_id: nil,
      text: entry.text,
      run_id: entry.run_id,
      inserted_at: ts,
      updated_at: ts
    }
  end

  defp type_for(:error), do: :failure
  defp type_for(_kind), do: :action

  defp resolve_refs(cache, entries) do
    entries
    |> Enum.map(fn {board_id, entry} -> {board_id, entry.ref} end)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(cache, &1))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce(cache, fn {board_id, refs}, acc ->
      board_id
      |> lookup(refs)
      |> Enum.reduce(acc, fn {ref, card_id}, inner -> Map.put(inner, {board_id, ref}, card_id) end)
    end)
  end

  # Only found refs are cached: a ref that misses (deleted card, stale worktree tag)
  # must stay re-resolvable, since the card may simply not exist yet.
  defp lookup(board_id, refs) do
    Repo.all(
      from c in Schemas.Card,
        join: b in Schemas.Board,
        on: b.id == c.board_id,
        where: c.board_id == ^board_id,
        where: fragment("? || '-' || ?", b.key, c.ref_number) in ^refs,
        select: {fragment("? || '-' || ?", b.key, c.ref_number), c.id}
    )
  end
end
