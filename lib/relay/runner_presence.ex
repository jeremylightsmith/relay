defmodule Relay.RunnerPresence do
  @moduledoc """
  Ephemeral per-board runner presence (RLY-141), following the `Relay.BoardWatch`
  pattern: a GenServer owning a **public named ETS table** so beats and reads never
  hop through the process. No DB — presence is lost on server restart by design (v0);
  cards 04/05 swap the data source (executor registration/claims) without changing
  the shape consumers see.

  Rows are keyed `{board_id, runner_id}` and hold the runner's last heartbeat
  payload as a snapshot map plus a server-clock `last_beat_at` (never the runner's
  clock). `beat/3` upserts and broadcasts `{:runner_beat, runner}` on
  `"board:<board_id>:runners"`; `RelayWeb.BoardRunnersLive` subscribes.

  The GenServer exists to own the table and run the prune sweep: every 10 minutes it
  drops runners whose last beat is older than 24 hours (card interview, decision 2 —
  a runner that died overnight is still visible the next morning). No broadcast on
  prune — the LiveView refetches on its own tick.

  Freshness (`freshness/2`) is derived at render time and never stored, in the same
  spirit as `Relay.Cards.health/1`: thresholds come from the runner's own promised
  `interval`, not a hardcoded server constant.
  """

  use Boundary, deps: []
  use GenServer

  @table :runner_presence
  @prune_every to_timeout(minute: 10)
  @retention to_timeout(day: 1)
  @default_interval 30
  @pubsub Relay.PubSub

  @doc "Starts the presence process and creates its public ETS table."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "The per-board runners topic."
  def topic(board_id), do: "board:#{board_id}:runners"

  @doc "Subscribes the calling process to `board_id`'s runners topic."
  def subscribe(board_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(board_id))

  @doc """
  Upserts the runner named by `payload["runner_id"]`, stamps `last_beat_at = now`
  (server clock — a parameter only so tests can backdate rows), and broadcasts
  `{:runner_beat, runner}` on `topic(board_id)`. Fire-and-forget: always `:ok`.
  `payload` is the string-keyed heartbeat JSON; anything malformed inside it
  degrades to safe defaults rather than raising — the runner beats best-effort
  and must never be told off.
  """
  def beat(board_id, payload, now \\ DateTime.utc_now()) when is_map(payload) do
    runner = snapshot(board_id, payload, now)
    :ets.insert(@table, {{board_id, runner.runner_id}, runner})
    Phoenix.PubSub.broadcast(@pubsub, topic(board_id), {:runner_beat, runner})
    :ok
  end

  @doc "All of `board_id`'s runners as snapshot maps, sorted by `started_at`."
  def list(board_id) do
    @table
    |> :ets.match_object({{board_id, :_}, :_})
    |> Enum.map(fn {_key, runner} -> runner end)
    |> Enum.sort_by(& &1.started_at, DateTime)
  end

  @doc """
  The runner's freshness at `now` — `:fresh` while the last beat is at most 1.5×
  the runner's own promised interval old, `:stale` up to 2×, `:gone` beyond (the
  card's "disconnected within two beat intervals"). Pure; takes `now` for
  testability.
  """
  def freshness(%{last_beat_at: at, interval: interval}, %DateTime{} = now) do
    age_ms = DateTime.diff(now, at, :millisecond)

    cond do
      age_ms <= 1.5 * interval * 1000 -> :fresh
      age_ms <= 2 * interval * 1000 -> :stale
      true -> :gone
    end
  end

  @doc """
  Deletes rows whose `last_beat_at` is more than 24 hours before `now`. The sweep
  timer calls this with the wall clock; public (and `now`-parameterized) so tests
  can sweep without waiting out the timer.
  """
  def prune(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@retention, :millisecond)

    @table
    |> :ets.tab2list()
    |> Enum.each(fn {key, runner} ->
      if DateTime.before?(runner.last_beat_at, cutoff), do: :ets.delete(@table, key)
    end)

    :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :prune, @prune_every)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    prune(DateTime.utc_now())
    Process.send_after(self(), :prune, @prune_every)
    {:noreply, state}
  end

  defp snapshot(board_id, payload, now) do
    %{
      board_id: board_id,
      runner_id: to_string(payload["runner_id"]),
      host: to_string(payload["host"] || ""),
      started_at: parse_datetime(payload["started_at"]) || now,
      interval: normalize_interval(payload["interval"]),
      pools: payload["pools"] |> as_list() |> Enum.filter(&is_map/1) |> Enum.map(&pool/1),
      jobs: payload["jobs"] |> as_list() |> Enum.filter(&is_map/1) |> Enum.map(&job/1),
      refs: payload["refs"] |> as_list() |> Enum.filter(&is_binary/1),
      last_beat_at: now
    }
  end

  defp pool(p) do
    %{
      name: to_string(p["name"] || "?"),
      mode: if(p["mode"] == "shared", do: :shared, else: :exclusive),
      used: non_neg_int(p["used"]),
      total: non_neg_int(p["total"])
    }
  end

  defp job(j) do
    %{
      ref: to_string(j["ref"] || "?"),
      stage: to_string(j["stage"] || ""),
      pool: if(j["pool"], do: to_string(j["pool"])),
      started_at: parse_datetime(j["started_at"])
    }
  end

  defp as_list(value) when is_list(value), do: value
  defp as_list(_value), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_interval(i) when is_integer(i) and i > 0, do: i
  defp normalize_interval(_i), do: @default_interval

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_n), do: 0
end
