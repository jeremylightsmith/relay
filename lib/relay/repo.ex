defmodule Relay.Repo do
  @moduledoc """
  The application's Ecto repo, plus a per-process **after-commit queue** (RE386).

  `after_commit/1` runs its callback immediately when no `Relay.Repo` transaction is open
  in the calling process. Inside one (at any nesting depth) it queues the callback instead.
  The queue is flushed in order once the **outermost** transaction returns `{:ok, _}`, and
  discarded on any other return or on a raise/throw/exit. `transact/2` is overridden to do
  this, and Ecto's `transaction/1,2` (functions and `Ecto.Multi`) delegates to it, so every
  transaction is hooked without any call site opting in.

  The nesting depth is tracked in the process dictionary by the override itself, and that
  counter alone decides whether to queue. `in_transaction?/0` is deliberately left alone: under
  the SQL sandbox it reports the sandbox's own transaction.
  """

  use Boundary, deps: []

  use Ecto.Repo,
    otp_app: :relay,
    adapter: Ecto.Adapters.Postgres

  require Logger

  @depth_key {__MODULE__, :transaction_depth}
  @queue_key {__MODULE__, :after_commit_queue}

  defoverridable transact: 2

  @impl Ecto.Repo
  def transact(fun_or_multi, opts) do
    run = fn -> super(fun_or_multi, opts) end

    case Process.get(@depth_key, 0) do
      0 -> outermost_transact(run)
      depth -> nested_transact(run, depth)
    end
  end

  # Only the outermost call owns the queue. Depth and queue are reset on every exit path
  # (including raise/throw/exit), and the queue is taken BEFORE any callback runs, since a
  # callback may open a transaction of its own.
  defp outermost_transact(run) do
    Process.put(@depth_key, 1)
    Process.put(@queue_key, [])

    {result, queued} =
      try do
        result = run.()
        {result, Process.get(@queue_key, [])}
      after
        Process.delete(@depth_key)
        Process.delete(@queue_key)
      end

    if match?({:ok, _}, result), do: queued |> Enum.reverse() |> Enum.each(&run_callback/1)
    result
  end

  defp nested_transact(run, depth) do
    Process.put(@depth_key, depth + 1)

    try do
      run.()
    after
      Process.put(@depth_key, depth)
    end
  end

  @doc """
  Runs `callback` after the calling process's outermost `Relay.Repo` transaction commits,
  or right away when no transaction is open. A rolled-back transaction drops it.
  """
  @spec after_commit((-> any())) :: :ok
  def after_commit(callback) when is_function(callback, 0) do
    if Process.get(@depth_key, 0) > 0 do
      Process.put(@queue_key, [callback | Process.get(@queue_key, [])])
    else
      callback.()
    end

    :ok
  end

  defp run_callback(callback) do
    callback.()
  rescue
    e -> Logger.error("Relay.Repo after_commit callback raised: " <> Exception.format(:error, e, __STACKTRACE__))
  catch
    kind, reason ->
      Logger.error("Relay.Repo after_commit callback failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end
end
