defmodule RelayWeb.ApiLog do
  @moduledoc """
  In-memory ring buffer of the last 200 inbound API requests, powering the
  `/admin/api` debug view. No persistence — cleared on restart.

  Each recorded entry is assigned a monotonically increasing `:id` and
  broadcast on `Relay.PubSub` topic `"api_log"` so `RelayWeb.Admin.ApiLive`
  can append it live. Secrets are never stored: the capture plug
  (`RelayWeb.Plugs.ApiLogger`) omits the Authorization header before calling
  `record/2`.
  """
  use GenServer

  @pubsub Relay.PubSub
  @topic "api_log"
  @max 200

  # Client -----------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Subscribes the calling process to new-entry broadcasts."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc "Records a request entry (async); assigns an `:id` and broadcasts it."
  def record(server \\ __MODULE__, entry), do: GenServer.cast(server, {:record, entry})

  @doc "Returns recorded entries, newest-first."
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "Drops all recorded entries."
  def clear(server \\ __MODULE__), do: GenServer.cast(server, :clear)

  # Server -----------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{entries: [], next_id: 1}}

  @impl true
  def handle_cast({:record, entry}, %{entries: entries, next_id: id}) do
    entry = Map.put(entry, :id, id)
    entries = Enum.take([entry | entries], @max)
    _ = Phoenix.PubSub.broadcast(@pubsub, @topic, {:api_log, entry})
    {:noreply, %{entries: entries, next_id: id + 1}}
  end

  def handle_cast(:clear, state), do: {:noreply, %{state | entries: []}}

  @impl true
  def handle_call(:list, _from, %{entries: entries} = state), do: {:reply, entries, state}
end
