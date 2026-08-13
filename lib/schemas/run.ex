defmodule Schemas.Run do
  @moduledoc """
  One flow traversal of one card (ADR 0006 card 02). A run points at the
  LIVE flow row — no definition snapshot and no version column (RLY-152);
  editing a flow can change in-flight runs, and a deleted flow nilifies
  `flow_id` (the next transition then fails loudly with `no_flow`).
  `flow_key` is denormalized at start for history display after deletion.

  No ENGINE counter columns: retry attempts, per-node visits, edge-loop
  counts, and breaker signatures are all derived from
  `Schemas.NodeExecution` history — one source of truth, restart-safe by
  construction. `retries` is the deliberate exception and is NOT an engine
  counter: it counts HUMAN retry interventions (RLY-189), which leave no
  trace in execution history and therefore cannot be derived from it. Only
  `Relay.Runs.retry_run/2` ever increments it. All fields are written
  programmatically by `Relay.Runs`, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "runs" do
    field :flow_key, :string
    field :status, Ecto.Enum, values: [:running, :parked, :done, :failed, :cancelled]
    field :parked_reason, Ecto.Enum, values: [:needs_input, :claimed, :executor_gone]
    field :pinned_executor_name, :string
    field :current_node, :string
    field :context, :map, default: %{}
    field :failure_detail, :string
    field :retries, :integer, default: 0

    field :resume_refused_since, :utc_datetime

    field :resume_refused_reason, Ecto.Enum,
      values: [:no_isolation, :pin_unresolved, :pinned_executor_absent, :no_free_slot]

    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :card, Schemas.Card
    belongs_to :flow, Schemas.Flow
    has_many :node_executions, Schemas.NodeExecution

    timestamps(type: :utc_datetime)
  end

  @doc "Run statuses where the traversal is still live (the run holds a card's active slot)."
  def active_statuses, do: [:running, :parked]

  @doc "Run statuses where the traversal has ended."
  def terminal_statuses, do: [:done, :failed, :cancelled]

  @doc "True when `status` is an active (running or parked) run status."
  def active?(status), do: status in active_statuses()

  @doc "The closed set of run statuses."
  def statuses, do: Ecto.Enum.values(__MODULE__, :status)

  @doc "The closed set of reasons a parked run is waiting."
  def parked_reasons, do: Ecto.Enum.values(__MODULE__, :parked_reason)

  @doc """
  The closed set of reasons the scheduler refused to resume a parked run (RE297).

    * `:no_isolation` — the run's flow row is gone, so it has no isolation class to place.
    * `:pin_unresolved` — an `:exclusive` run with no resolvable executor pin.
    * `:pinned_executor_absent` — the pinned executor is not in the capacity map (`:gone`, or
      it never advertised).
    * `:no_free_slot` — everything resolved; the class simply has no free slot right now.

  The `Ecto.Enum` above and `Relay.Runs.Scheduler`'s classification both read this one list.
  """
  def resume_refusal_reasons, do: Ecto.Enum.values(__MODULE__, :resume_refused_reason)

  @doc """
  The partition of `resume_refusal_reasons/0` that PROVES a run's executor pin can never be
  honoured, so `Relay.Runs.abandon_unresumable_runs/1` clears it when it gives up. The other
  reasons mean the machine is alive and the run's worktree really is still on it, so the pin
  is kept and a retry must land back there.
  """
  def pin_unhonourable_refusal_reasons, do: [:pin_unresolved, :pinned_executor_absent]

  @doc """
  Validates a programmatically-built run. The partial unique index
  `runs_one_active_per_card_index` enforces at most one active
  (running/parked) run per card; the constraint is mapped so a race
  surfaces as a changeset error, not a raise.
  """
  def changeset(run) do
    run
    |> change()
    |> validate_required([:card_id, :flow_key, :status])
    |> foreign_key_constraint(:card_id)
    |> unique_constraint(:card_id, name: :runs_one_active_per_card_index)
  end
end
