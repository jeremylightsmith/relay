defmodule Schemas.NodeJob do
  @moduledoc """
  The dispatch unit (ADR 0006 card 02): the durable record of "this node
  attempt is available to an executor" — queued | claimed | done | revoked.
  One job per `NodeExecution` attempt. Persisted so cancel/revoke and
  restart-resume read from durable state; card 04 adds only the REST
  claim/report transport on top of these rows.
  `executor_name` stays a plain string until the Executor table (04).
  `payload` is the executor's whole contract:
  `%{"run" => raw run string, "node_type" => ..., "isolation" => ...,
  "resume_session" => sid | nil, "vars" => %{...}}` — placeholder
  expansion stays executor-side (see `Schemas.Flow.Node`). `inserted_at`
  is queued-at. All fields programmatic, never cast.

  There is deliberately no `:running`: an executor claims a job and starts
  its worker in the same loop iteration, so `:claimed` IS running (RE255).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "node_jobs" do
    field :node_key, :string
    field :state, Ecto.Enum, values: [:queued, :claimed, :done, :revoked]
    field :executor_name, :string
    field :payload, :map, default: %{}
    field :claimed_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :kind, Ecto.Enum, values: [:node, :talk], default: :node

    belongs_to :run, Schemas.Run
    belongs_to :node_execution, Schemas.NodeExecution
    belongs_to :card, Schemas.Card

    timestamps(type: :utc_datetime)
  end

  @doc "Job states where the dispatch unit is still live (queued or claimed)."
  def active_states, do: [:queued, :claimed]

  @doc ~S"""
  Job states held by a LIVE claim — excludes `:queued`, which nobody holds. Deliberately distinct
  from `active_states/0` even though only `:claimed` currently satisfies it: `active_states/0`
  means "not finished," while this means "an executor is holding and working it," which is what
  `Relay.Runs.get_claimed_job/2` and the board's `working_run_ids/2` need. A future consumer must
  not reach for `active_states/0` when it means held — `:queued` is active but worked by nobody.
  """
  def claimed_states, do: [:claimed]

  @doc "The closed set of node-job states."
  def states, do: Ecto.Enum.values(__MODULE__, :state)

  @doc ~S"""
  The closed set of dispatchers that write this table (ADR 0009). `:node` is a flow-dispatched
  node job; `:talk` is one turn of a person-driven Talk session, carrying no run. Defined ONCE
  here — no consumer re-types either literal.
  """
  def kinds, do: Ecto.Enum.values(__MODULE__, :kind)

  @doc "The kinds a FLOW dispatches — every query that means \"the engine's jobs\" filters on this."
  def flow_kinds, do: [:node]

  @doc "The single person-dispatched kind (ADR 0009). Deliberately scalar: there is one, and code that means \"this is a talk turn\" should read as a comparison, not a membership test."
  def talk_kind, do: :talk

  @doc ~S"""
  Validates a programmatically-built job row. `run_id`/`node_execution_id` are required for a
  flow job and forbidden for a talk turn — a talk turn deliberately synthesises no `Run`
  (ADR 0009), because a Run would make every card with an open conversation read as having an
  active run. `card_id` is required for both: it is the board-scoping join for the whole table.
  """
  def changeset(job) do
    job
    |> change()
    |> validate_required([:card_id, :node_key, :state, :kind])
    |> validate_kind_shape()
    |> foreign_key_constraint(:card_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:node_execution_id)
  end

  defp validate_kind_shape(changeset) do
    case get_field(changeset, :kind) do
      :talk ->
        changeset
        |> validate_nil(:run_id)
        |> validate_nil(:node_execution_id)

      _flow ->
        validate_required(changeset, [:run_id, :node_execution_id])
    end
  end

  defp validate_nil(changeset, field) do
    if is_nil(get_field(changeset, field)) do
      changeset
    else
      add_error(changeset, field, "must be nil on a talk job")
    end
  end
end
