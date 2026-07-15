defmodule Relay.Activity.Pruner do
  @moduledoc """
  Time-based retention for runner chatter (RLY-112, Q4→C): every 6 hours, drops
  `:action` entries older than 14 days.

  **Matches on `type == :action`, never on `Relay.Activity.kind/1`** — `kind` maps the
  legacy audit types (`:created`, `:status_changed`, …) to `:action` too, so pruning by
  kind would delete the card's audit trail. `type == :action` is exactly the runner
  lines. Moves, decisions, failures and every audit type are never pruned: the card's
  story survives, only the chatter ages out.

  14 days is long enough that a card worked over a fortnight keeps its full story for
  review, short enough to bound a table that takes thousands of rows per run. It is a
  module attribute — change it in one line if it's wrong.

  Served by the `activities_action_pruning_index` partial index. Runs on the same
  interval in every env; the first sweep is one full interval after boot, so starting
  this process never touches the DB.
  """

  use GenServer

  import Ecto.Query

  alias Relay.Repo

  @interval to_timeout(hour: 6)
  @retain_days 14

  @doc "Starts the pruner. `opts[:name]` and `opts[:interval]` override the defaults."
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    {:ok, %{interval: interval, timer: schedule(interval)}}
  end

  @impl true
  def handle_info(:prune, state) do
    prune()
    {:noreply, %{state | timer: schedule(state.interval)}}
  end

  defp schedule(interval), do: Process.send_after(self(), :prune, interval)

  defp prune do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@retain_days * 24 * 3600, :second)
      |> DateTime.truncate(:second)

    Repo.delete_all(from a in Schemas.Activity, where: a.type == :action and a.inserted_at < ^cutoff)
  end
end
