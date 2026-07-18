defmodule RelayWeb.Api.BoardController do
  use RelayWeb, :controller

  alias Relay.AgentLog
  alias Relay.Boards
  alias Relay.BoardWatch
  alias Relay.Cards
  alias Relay.RunnerPresence
  alias Relay.Runs

  action_fallback RelayWeb.Api.FallbackController

  def show(conn, params) do
    board = conn.assigns.current_board
    stages = Boards.list_stages(board)
    render(conn, :show, board: board, stages: stages, cards: index_cards(board, stages, params))
  end

  def version(conn, _params) do
    version = BoardWatch.version(conn.assigns.current_board.id)

    conn
    |> put_resp_header("etag", Integer.to_string(version))
    |> json(%{version: version})
  end

  def logs(conn, params) do
    entries = Map.get(params, "_json", [])
    :ok = AgentLog.record(conn.assigns.current_board.id, entries)
    send_resp(conn, 200, "")
  end

  def heartbeat(conn, params) do
    board = conn.assigns.current_board
    refs = Map.get(params, "refs", [])
    refs = if is_list(refs), do: refs, else: []
    {stamped, _} = Cards.touch_heartbeats(board, refs)

    # RLY-141: a runner_id marks the presence-carrying payload; a legacy refs-only
    # beat (an old runner binary) still stamps cards above and never appears in
    # presence.
    case params do
      %{"runner_id" => runner_id} when is_binary(runner_id) and runner_id != "" ->
        :ok = RunnerPresence.beat(board.id, params)

      _ ->
        :ok
    end

    # RLY-134/RLY-136: an executor beat is a superset — it carries `name` + `capacity`,
    # upserts the durable Executor row, AND advertises capacity into Relay.Runs.Capacity
    # (the ETS store the scheduler reads). Keyed by the durable Executor row id. The
    # `capacity` carried here is the executor's *configured* per-class slot count, not a
    # live free count — Relay.Runs.Scheduler.Server debits in-flight :running runs from
    # it server-side before planning (see Relay.Runs.Capacity's moduledoc).
    :ok = maybe_advertise_executor(board, params)

    json(conn, %{stamped: stamped})
  end

  defp maybe_advertise_executor(board, %{"capacity" => capacity, "name" => name} = params)
       when is_map(capacity) and is_binary(name) and name != "" do
    case Runs.upsert_executor(board, params) do
      {:ok, executor} -> Runs.Capacity.put(executor.id, atomize_capacity(capacity))
      _error -> :ok
    end
  end

  defp maybe_advertise_executor(_board, _params), do: :ok

  # JSON delivers string-keyed classes; Relay.Runs.Capacity keys on atoms. Only the
  # two known isolation classes cross over; anything else is dropped (never String.to_atom
  # on request data — memory-leak risk).
  defp atomize_capacity(capacity) do
    %{
      shared_clean: capacity_int(capacity, "shared_clean"),
      exclusive: capacity_int(capacity, "exclusive")
    }
  end

  defp capacity_int(capacity, key) do
    case Map.get(capacity, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  # RLY-67: the board index drops the top-level Done column unless ?include_done is set.
  defp index_cards(board, stages, params) do
    if include_done?(params) do
      Cards.list_cards(board)
    else
      Cards.list_cards(board, exclude_stage_ids: Boards.top_level_done_stage_ids(stages))
    end
  end

  defp include_done?(params), do: params["include_done"] in ["1", "true", true]
end
