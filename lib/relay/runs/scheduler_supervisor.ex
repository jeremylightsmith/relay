defmodule Relay.Runs.SchedulerSupervisor do
  @moduledoc """
  DynamicSupervisor for the per-board `Relay.Runs.Scheduler.Server` processes,
  each keyed in `Relay.Runs.SchedulerRegistry`. `ensure_started/2` is idempotent
  (returns the existing pid if the board already has a scheduler). `reconcile/1`
  adopts every board that has none and is the real lifecycle: it runs at boot
  (`start_all/0`) **and** on every `RunnerReaper` sweep, because a board can become
  dispatch-eligible long after boot and a board with no scheduler silently never
  dispatches (RE387). Both are no-ops unless `:runs_auto_start` is configured true
  (dev/prod); in test they do nothing, so booting never queries the DB from an
  un-checked-out process.
  """

  use DynamicSupervisor

  alias Relay.Runs.Scheduler.Server

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Starts (or returns the already-running) scheduler for `board_id`."
  def ensure_started(board_id, opts \\ []) do
    # ADR 0009 rule 2: this DynamicSupervisor severs $callers, so hand the chain down explicitly
    # unless the caller supplied its own. A no-op in production.
    child_opts =
      opts
      |> Keyword.put(:board_id, board_id)
      |> Keyword.put_new(:callers, Relay.Runs.Instance.callers())

    case DynamicSupervisor.start_child(__MODULE__, {Server, child_opts}) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Starts a scheduler for every non-archived board that does not already have one.

  The scheduler is the only thing that ticks a board and the only subscriber to its
  `card_moved` events, so a board with no scheduler never dispatches: its cards sit
  `ready` forever and runners have nothing to claim. Enumerating boards **once** at boot
  stranded every board that appeared later — created, unarchived, or restored — which is
  why this is a reconciliation the clock repeats rather than a one-shot
  (`RunnerReaper` calls it every sweep, RE387).

  Idempotent, and a no-op unless `:runs_auto_start` is on (off in test, so booting never
  queries the DB from an un-checked-out process).
  """
  def reconcile(opts \\ []) do
    if Relay.Config.get(:runs_auto_start, false) do
      Relay.Boards.list_board_ids()
      |> Enum.reject(&scheduler_running?/1)
      |> Enum.each(&ensure_started(&1, opts))
    end

    :ok
  end

  @doc "True when `board_id` already has a scheduler registered."
  def scheduler_running?(board_id), do: Registry.lookup(Relay.Runs.SchedulerRegistry, board_id) != []

  @doc "Starts a scheduler for every existing board — only when :runs_auto_start is on."
  def start_all, do: reconcile()
end
