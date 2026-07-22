defmodule Relay.Runs.Transitions do
  @moduledoc """
  The one greppable place `Run.status`'s state machine is written down (RLY-206).

  The legal graph lives as data (`@transitions`, a list of `{from, to, meaning}`), and every
  run-status write goes through the single guarded-`UPDATE` helper `transition/4` — a mirror of
  `Relay.Runs`' `transition_job/3` for node-jobs. A lost race is a detected, logged no-op
  (`{:error, :not_in_expected_state}`), never a silent overwrite of a stale struct.

  The `meaning` column is co-located with each edge so `mix relay.gen_state` (RLY-206, Part 3)
  can render the human-readable transition table in `docs/architecture/state.md` straight from
  this data — one source of truth for both the engine and the doc.

  Internal to the `Relay.Runs` boundary; not exported, not called from `RelayWeb`.
  """

  import Ecto.Query

  alias Relay.Repo
  alias Schemas.Run

  require Logger

  # from, to, meaning (meaning feeds the generated state.md table — Part 3).
  # `done` and `cancelled` are terminal; `failed` is terminal-except-retry.
  @transitions [
    {:running, :parked, "park (reason: `needs_input` \\| `claimed` \\| `executor_gone`)"},
    {:running, :done, "flow reached its `done` target"},
    {:running, :failed, "engine gave up (no route / caps / breaker)"},
    {:running, :cancelled, "human cancelled a live run"},
    {:parked, :running, "resume"},
    {:parked, :cancelled, "human cancelled a parked run"},
    {:failed, :running, "human retry / `revive_run` (RLY-189)"}
  ]

  @doc "The legal graph as `{from, to, meaning}` triples — the source `mix relay.gen_state` renders."
  @spec transitions() :: [{atom(), atom(), String.t()}]
  def transitions, do: @transitions

  @doc "The `{from, to}` pairs of the legal graph (meaning dropped)."
  @spec edges() :: MapSet.t()
  def edges, do: MapSet.new(@transitions, fn {from, to, _meaning} -> {from, to} end)

  @doc "Whether `from -> to` is a declared edge."
  @spec legal?(atom(), atom()) :: boolean()
  def legal?(from, to), do: MapSet.member?(edges(), {from, to})

  @doc """
  Guarded run-status write: `UPDATE runs SET status = to_status (++ opts[:set])
  WHERE id = run.id AND status IN from_states`.

  * `{1, [updated]}` -> `{:ok, updated}`.
  * `{0, _}` -> a `Logger.warning` naming the run, the attempted status, and the expected
    from-states, then `{:error, :not_in_expected_state}` — a visible, logged no-op.

  Raises `ArgumentError` if any declared `{from, to_status}` is not `legal?/2` (a caller bug,
  caught by tests — never a runtime refusal). `opts[:set]` is merged after `status:`.
  """
  @spec transition(Run.t(), [atom()], atom(), keyword()) ::
          {:ok, Run.t()} | {:error, :not_in_expected_state}
  def transition(%Run{id: id} = _run, from_states, to_status, opts \\ []) do
    Enum.each(from_states, fn from ->
      if !legal?(from, to_status) do
        raise ArgumentError,
              "illegal run transition #{inspect(from)} -> #{inspect(to_status)} " <>
                "(not in Relay.Runs.Transitions' legal graph)"
      end
    end)

    set = [status: to_status] ++ Keyword.get(opts, :set, [])
    query = from(r in Run, where: r.id == ^id and r.status in ^from_states, select: r)

    case Repo.update_all(query, set: set) do
      {1, [updated]} ->
        {:ok, updated}

      {0, _none} ->
        Logger.warning(
          "run #{id}: refused transition to #{inspect(to_status)} — " <>
            "not in expected state #{inspect(from_states)}"
        )

        {:error, :not_in_expected_state}
    end
  end
end
