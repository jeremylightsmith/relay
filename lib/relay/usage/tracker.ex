defmodule Relay.Usage.Tracker do
  @moduledoc """
  The only writer of `usage_visits` (RE475). Callers `touch/3` it with the signed-in user (the
  `RelayWeb.UsageTrack` hook and plug); it keeps one open visit per user in memory and upserts the
  dirty ones in a single `insert_all` every `Relay.Usage.flush_ms/0`, on the `(user_id, started_at)`
  unique key, so it never tracks row ids. A flush with nothing dirty issues no query.

  A touch more than `Relay.Usage.idle_gap/0` after the visit's last touch opens a new visit; the old
  one, if it still has unwritten changes, waits in `pending` for the next flush. A touch stamped
  *earlier* than the visit's last touch (the plug's dead render and the LiveView's connected mount
  run in different processes) only extends it. A written visit that has gone idle past the gap
  leaves memory on the next flush.

  Best-effort by construction, like `Relay.Activity.LogSink`: `touch/3` is a fire-and-forget cast
  that never blocks or fails the request — with the tracker not running (`:usage_tracking` is off
  in test) a cast to its name is a silent no-op — and it never queries the DB per touch. If this
  process crashes the supervisor restarts it and the in-memory visits are lost; a DB error drops
  the whole batch rather than retrying it — every user's visits in that flush, not only the bad
  row, since it is one `insert_all` (a deleted user's FK failure would otherwise poison every later
  flush). Either way at most one minute of usage is lost. A graceful shutdown flushes first
  (`trap_exit` + `terminate/2`).
  """

  use GenServer

  alias Relay.Repo
  alias Relay.Usage
  alias Schemas.User

  require Logger

  @max_ref_bytes 32
  @replaced [:last_at, :seconds, :board_id, :card_refs, :updated_at]

  @doc """
  Starts the tracker. `opts[:name]` defaults to `#{inspect(__MODULE__)}`; `opts[:flush_ms]` to
  `Relay.Usage.flush_ms/0`.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records that `user` was active, optionally on `attrs.board_id` with `attrs.card_ref` open.
  Always `:ok`, a cast. A nil or synthetic user (`Schemas.User.synthetic?/1`) is skipped without
  casting; a `card_ref` that is not a 1..#{@max_ref_bytes}-byte binary is dropped (the touch still
  counts). Opts: `:server` (default `Relay.Config.get(:usage_tracker, #{inspect(__MODULE__)})`) and
  `:at` (default now, to the second).
  """
  @spec touch(
          User.t() | nil,
          %{optional(:board_id) => integer() | nil, optional(:card_ref) => String.t() | nil},
          keyword()
        ) ::
          :ok
  def touch(user, attrs, opts \\ [])

  def touch(nil, _attrs, _opts), do: :ok

  def touch(%User{id: user_id} = user, attrs, opts) do
    if User.synthetic?(user) do
      :ok
    else
      server = Keyword.get_lazy(opts, :server, fn -> Relay.Config.get(:usage_tracker, __MODULE__) end)
      at = opts |> Keyword.get_lazy(:at, &DateTime.utc_now/0) |> DateTime.truncate(:second)
      GenServer.cast(server, {:touch, user_id, at, Map.get(attrs, :board_id), valid_ref(Map.get(attrs, :card_ref))})
    end
  end

  @doc "Writes every dirty visit now; returns how many rows it upserted (`{:ok, 0}`, no query, when none)."
  @spec flush(GenServer.server()) :: {:ok, non_neg_integer()}
  def flush(server), do: GenServer.call(server, :flush)

  @doc "The in-memory open visit per user id (for tests)."
  @spec open_visits(GenServer.server()) :: %{
          integer() => %{
            started_at: DateTime.t(),
            last_at: DateTime.t(),
            board_id: integer() | nil,
            card_refs: [String.t()],
            dirty?: boolean()
          }
        }
  def open_visits(server), do: GenServer.call(server, :open_visits)

  defp valid_ref(ref) when is_binary(ref) and byte_size(ref) in 1..@max_ref_bytes, do: ref
  defp valid_ref(_ref), do: nil

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = %{visits: %{}, pending: [], flush_ms: Keyword.get(opts, :flush_ms, Usage.flush_ms())}
    {:ok, schedule(state)}
  end

  @impl true
  def handle_cast({:touch, user_id, at, board_id, card_ref}, state) do
    {:noreply, record(state, user_id, at, board_id, card_ref)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {count, state} = do_flush(state)
    {:reply, {:ok, count}, state}
  end

  def handle_call(:open_visits, _from, state), do: {:reply, state.visits, state}

  @impl true
  def handle_info(:flush, state) do
    {_count, state} = do_flush(state)
    {:noreply, schedule(state)}
  end

  @impl true
  def terminate(_reason, state) do
    do_flush(state)
    :ok
  end

  defp schedule(state) do
    Process.send_after(self(), :flush, state.flush_ms)
    state
  end

  defp record(state, user_id, at, board_id, card_ref) do
    visit = Map.get(state.visits, user_id)

    cond do
      is_nil(visit) ->
        put_visit(state, user_id, open(at, board_id, card_ref))

      DateTime.diff(at, visit.last_at) > Usage.idle_gap() ->
        state |> close(user_id, visit) |> put_visit(user_id, open(at, board_id, card_ref))

      true ->
        put_visit(state, user_id, extend(visit, at, board_id, card_ref))
    end
  end

  defp put_visit(state, user_id, visit), do: %{state | visits: Map.put(state.visits, user_id, visit)}

  # A closed visit with unwritten changes waits for the next flush; a clean one is already written.
  defp close(state, user_id, %{dirty?: true} = visit), do: %{state | pending: [{user_id, visit} | state.pending]}
  defp close(state, _user_id, _visit), do: state

  defp open(at, board_id, card_ref) do
    %{started_at: at, last_at: at, board_id: board_id, card_refs: add_ref([], card_ref), dirty?: true}
  end

  defp extend(visit, at, board_id, card_ref) do
    %{
      visit
      | last_at: Enum.max([visit.last_at, at], DateTime),
        board_id: board_id || visit.board_id,
        card_refs: add_ref(visit.card_refs, card_ref),
        dirty?: true
    }
  end

  # Most recently touched last, no duplicates, the oldest dropped past the cap.
  defp add_ref(refs, nil), do: refs
  defp add_ref(refs, ref), do: refs |> List.delete(ref) |> Kernel.++([ref]) |> Enum.take(-Usage.max_card_refs())

  defp do_flush(state) do
    dirty = state.pending ++ Enum.filter(state.visits, fn {_user_id, visit} -> visit.dirty? end)
    count = write(dirty)
    {count, %{state | pending: [], visits: settle(state.visits)}}
  end

  # Every open visit is clean after a flush (written, or dropped with its batch); one that was
  # already clean and has gone idle past the gap has had its final write, so it leaves memory.
  defp settle(visits) do
    cutoff = DateTime.add(DateTime.utc_now(), -Usage.idle_gap())

    Map.new(
      for {user_id, visit} <- visits,
          visit.dirty? or DateTime.after?(visit.last_at, cutoff),
          do: {user_id, %{visit | dirty?: false}}
    )
  end

  defp write([]), do: 0

  defp write(dirty) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    rows = Enum.map(dirty, fn {user_id, visit} -> row(user_id, visit, now) end)

    {count, _rows} =
      Repo.insert_all(Schemas.UsageVisit, rows,
        on_conflict: {:replace, @replaced},
        conflict_target: [:user_id, :started_at]
      )

    count
  rescue
    error ->
      Logger.warning("Usage tracker dropped #{length(dirty)} visit(s): #{error_summary(error)}")
      0
  end

  defp row(user_id, visit, now) do
    %{
      user_id: user_id,
      started_at: visit.started_at,
      last_at: visit.last_at,
      seconds: Usage.visit_seconds(visit.started_at, visit.last_at),
      board_id: visit.board_id,
      card_refs: visit.card_refs,
      inserted_at: now,
      updated_at: now
    }
  end

  # One line, as in LogSink: a sandbox `DBConnection.OwnershipError` carries a ~25-line essay.
  defp error_summary(error) do
    error |> Exception.message() |> String.split("\n", parts: 2) |> hd()
  end
end
