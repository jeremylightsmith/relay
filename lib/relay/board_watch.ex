defmodule Relay.BoardWatch do
  @moduledoc """
  Per-board monotonic version counter (RLY-12), backed by a public named ETS
  table so reads and bumps never hop through the GenServer.

  Every domain mutation funnels through `Relay.Events.broadcast/2`, which is
  the single call site for `bump/1`; any board activity — create, move, edit,
  status, owner, comment, stage change — advances that board's version. The
  CLI polls `version/1` and only refetches the full board when it moves.

  The GenServer exists solely to own the table (so it outlives any caller); it
  holds no other state and handles nothing on the hot path.
  """

  use Boundary, deps: []
  use GenServer

  @table :board_versions

  @doc "Starts the counter process and creates its public ETS table."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Atomically bumps `board_id`'s version and returns the new value. The first
  bump for a board seeds the counter from `System.os_time(:second)`, so
  versions keep climbing across server restarts and two distinct board states
  can't collide on a small integer after a restart. Any process may call this;
  there is no message hop.
  """
  def bump(board_id) do
    :ets.update_counter(@table, board_id, {2, 1}, {board_id, System.os_time(:second)})
  end

  @doc "Returns `board_id`'s current version, or `0` if it has never been bumped."
  def version(board_id) do
    case :ets.lookup(@table, board_id) do
      [{^board_id, version}] -> version
      [] -> 0
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
