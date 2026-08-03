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

    belongs_to :run, Schemas.Run
    belongs_to :node_execution, Schemas.NodeExecution

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

  @doc "Validates a programmatically-built job row."
  def changeset(job) do
    job
    |> change()
    |> validate_required([:run_id, :node_execution_id, :node_key, :state])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:node_execution_id)
  end
end
