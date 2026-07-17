defmodule Schemas.NodeExecution do
  @moduledoc """
  One attempt of one node within a run (ADR 0006 card 02) — the history
  W8 renders and the engine derives every cap from. `visit` increments
  each time the node is entered via an edge; `attempt` is 1-based within a
  visit (retries). `outcome` is nil while in flight and STAYS nil for an
  abandoned/revoked attempt — caps count outcomes, not rows.
  `failure_signature` (SHA-1 of normalized `detail`) powers the circuit
  breaker; `git_sha` anchors engine state to code state; `session_id`
  powers `--resume` on needs-input re-entry; `cost` is executor-reported
  (04/05; schema-ready now). All fields programmatic, never cast.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "node_executions" do
    field :node_key, :string
    field :visit, :integer
    field :attempt, :integer
    field :outcome, Ecto.Enum, values: [:succeeded, :failed, :partial, :needs_input]
    field :detail, :string
    field :failure_signature, :string
    field :git_sha, :string
    field :session_id, :string
    field :cost, :decimal
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :run, Schemas.Run

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built execution row."
  def changeset(execution) do
    execution
    |> change()
    |> validate_required([:run_id, :node_key, :visit, :attempt])
    |> foreign_key_constraint(:run_id)
  end
end
