defmodule Relay.Runs.SchedulerSupervisor do
  @moduledoc """
  DynamicSupervisor for the per-board `Relay.Runs.Scheduler.Server` processes,
  each keyed in `Relay.Runs.SchedulerRegistry`. `ensure_started/2` is idempotent
  (returns the existing pid if the board already has a scheduler). `start_all/0`
  runs at boot **only** when `:runs_auto_start` is configured true (dev/prod);
  in test it is a no-op, so booting never queries the DB from an un-checked-out
  process.
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

  @doc "Starts a scheduler for every existing board — only when :runs_auto_start is on."
  def start_all do
    if Application.get_env(:relay, :runs_auto_start, false) do
      Enum.each(Relay.Boards.list_board_ids(), &ensure_started/1)
    end

    :ok
  end
end
