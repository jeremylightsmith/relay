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
    field :current_node, :string
    field :context, :map, default: %{}
    field :failure_detail, :string
    field :retries, :integer, default: 0
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :card, Schemas.Card
    belongs_to :flow, Schemas.Flow
    has_many :node_executions, Schemas.NodeExecution

    timestamps(type: :utc_datetime)
  end

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
