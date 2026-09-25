defmodule Schemas.NodeExecution do
  @moduledoc """
  One attempt of one node within a run (ADR 0006 card 02) — the history
  W8 renders and the engine derives every cap from. `visit` increments
  each time the node is entered via an edge; `attempt` is 1-based within a
  visit (retries). `outcome` is nil while in flight and STAYS nil for an
  abandoned/revoked attempt — caps count outcomes, not rows.
  `failure_signature` (SHA-1 of normalized `detail`) powers the circuit
  breaker; `git_sha` anchors engine state to code state; `session_id`
  powers `--resume` on needs-input re-entry; `cost` is runner-reported
  (04/05; schema-ready now). All fields programmatic, never cast.

  `sub_task_id` binds the execution to one `foreach` ITERATION (nil outside a
  foreach): it is what makes "which task is in flight" renderable on the card,
  and it is the key `Engine.decide/4` scopes `max_loops`/`max_retries`/the
  visit cap to. Programmatic, never cast.

  `no_changes` records that the node ASSERTED "succeeded, and no changes were needed" (RE310) —
  what was claimed, not what the engine decided, so a rejected claim is still readable as
  `no_changes: true` with `outcome: :failed`.

  `:blocked` (RE308) is reported ONLY by the runner, never declared by an agent: "the agent could
  not run at all" — an expired login or a usage limit. The engine parks on it before any edge is
  consulted, so it is in `outcomes/0` (what a runner may report) but not in `routable_outcomes/0`
  (what a flow edge may route on and an agent may declare).

  `resume_at` (RE267) is set ONLY on a `:blocked` row, and only when the runner knew when the
  usage limit that refused the agent resets (a rejected `rate_limit_event`'s `resetsAt`). Its
  presence is what `Relay.Runs.Engine.decide/4` reads to requeue the node instead of parking it;
  an auth failure, `billing_error`, or a phrase-only usage limit leaves it nil and parks (RE308).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "node_executions" do
    field :node_key, :string
    field :visit, :integer
    field :attempt, :integer
    field :outcome, Ecto.Enum, values: [:succeeded, :failed, :partial, :needs_input, :blocked]
    field :detail, :string
    field :failure_signature, :string
    field :git_sha, :string
    field :no_changes, :boolean, default: false
    field :session_id, :string
    field :cost, :decimal
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :sub_task_id, :integer
    field :resume_at, :utc_datetime

    belongs_to :run, Schemas.Run

    timestamps(type: :utc_datetime)
  end

  # RE308: reported by the runner only — never agent-declarable, never routable.
  @runner_only_outcomes [:blocked]

  @doc "The closed set of node outcomes a runner may report."
  def outcomes, do: Ecto.Enum.values(__MODULE__, :outcome)

  @doc """
  The outcomes a flow edge may route `on:` — and, identically, the ones an agent may declare
  (`./relay`'s `NODE_OUTCOMES`, pinned as the contract fixture's `agent_outcomes`). Excludes
  `:blocked` (RE308): the engine parks on it before any edge is consulted, and a flow able to route
  around that park could spend a retry budget on a condition retrying cannot fix.
  """
  def routable_outcomes, do: outcomes() -- @runner_only_outcomes

  @doc "Validates a programmatically-built execution row."
  def changeset(execution) do
    execution
    |> change()
    |> validate_required([:run_id, :node_key, :visit, :attempt])
    |> foreign_key_constraint(:run_id)
  end
end
