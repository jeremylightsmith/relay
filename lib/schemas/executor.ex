defmodule Schemas.Executor do
  @moduledoc """
  A durable executor registration (ADR 0006 card 04): the developer machine
  that pulls node-jobs. Keyed uniquely on `{board_id, name}` and refreshed on
  every claim / executor heartbeat. `capacity` is the last-advertised
  **configured** slot count per isolation class (not a live free count — see
  `Relay.Runs.Capacity`), normalized to the closed set and stored STRING-keyed:
  `%{"shared_clean" => 3, "exclusive" => 1}`. Unknown classes never reach the
  row (RLY-201). **That guarantee now has a single enforcement point (RE311):**
  `RelayWeb.Api.NodeJobController` puts `capacity` on the upsert attrs from the
  HEARTBEAT action only — the claim's `capacity` is the executor's live FREE
  count and is passed to `Relay.Runs.claim_next_job/3` as an argument instead of
  being written here, so one column can no longer carry two meanings.
  `last_heartbeat` drives reclaim:
  an executor silent past `max(60s, 2 × interval)` is stale and its in-flight
  jobs are recovered. `capabilities` is the last-reported inventory of what this
  executor can resolve by name — `%{"agents" => [...], "skills" => [...]}` — or
  `nil` when it has never reported one (RLY-182). All fields are set
  programmatically by `Relay.Runs`.

  `version` is the `EXECUTOR_VERSION` the running `bin/relay` declares (RLY-184); `nil` means
  an executor predating that card, which `Relay.Runs.executor_outdated?/1` treats as behind.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "executors" do
    field :name, :string
    field :host, :string
    field :interval, :integer, default: 30
    field :capacity, :map, default: %{}
    # No default: nil means "never reported its inventory" and is deliberately distinct
    # from %{} ("reported, and empty"). Preflight branches on that difference.
    field :capabilities, :map
    # RE311: heartbeat-written, defaulting to [] rather than nil — unlike `capabilities`,
    # nothing branches on "never reported" here: an executor holding nothing and an executor
    # that has not said are the same thing for occupancy purposes, and [] keeps every reader
    # (chip count, tooltip, diagnosis) free of a nil case.
    field :held, {:array, :map}, default: []
    field :version, :integer
    field :last_heartbeat, :utc_datetime

    belongs_to :board, Schemas.Board

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built executor row."
  def changeset(executor, attrs) do
    executor
    |> cast(attrs, [
      :board_id,
      :name,
      :host,
      :interval,
      :capacity,
      :capabilities,
      :held,
      :version,
      :last_heartbeat
    ])
    |> validate_required([:board_id, :name, :last_heartbeat])
    |> foreign_key_constraint(:board_id)
    |> unique_constraint([:board_id, :name], name: :executors_board_id_name_index)
  end

  # RE311 — the closed set of per-card worktree states an executor can declare it HOLDS,
  # defined exactly once on this side and mirrored in `bin/relay`'s HOLDING_STATES, which the
  # executor contract fixture (`vocabulary.holding_states`) pins to this function. Strings,
  # not atoms: this vocabulary only ever arrives off the wire and is only ever compared to
  # wire values, so atomizing it would buy nothing and add a conversion at every use site.
  @holding_states ["bound", "retained", "running", "talk"]

  # The three that occupy an exclusive partition. `retained` is a failed run's leftover held
  # for post-mortem: it holds no partition, the executor evicts it on its own terms, and
  # `assign()` refuses it at full capacity — so offering work for a retained ref would produce
  # a claimed-then-rejected job.
  @active_holding_states ["bound", "running", "talk"]

  @doc """
  Every state an executor may declare for a held per-card worktree.

    * `running` — active worktree with a live job
    * `bound` — active worktree, no live job, awaiting its run's next node
    * `talk` — active worktree a talk turn is attached to
    * `retained` — a failed run's leftover, kept for post-mortem; holds no partition
  """
  def holding_states, do: @holding_states

  @doc "The subset of `holding_states/0` that occupies an exclusive partition."
  def active_holding_states, do: @active_holding_states

  @doc """
  The one normalizer for the `held` wire field: a list of `%{"ref" => ref, "state" => state}`
  with a binary ref and a state in `holding_states/0`. Everything else is DROPPED.

  Total by construction — any term in, a list out. Untrusted input degrades, never raises: a
  stray entry from an older or newer executor must not 500 the claim or the heartbeat, which
  are that executor's liveness path (the RLY-201 lesson, applied to a second field).
  """
  def normalize_held(held) when is_list(held) do
    for %{"ref" => ref, "state" => state} <- held,
        is_binary(ref),
        state in @holding_states,
        do: %{"ref" => ref, "state" => state}
  end

  def normalize_held(_held), do: []

  @doc """
  The refs whose declared state occupies an exclusive partition — the refs whose worktree the
  executor is genuinely holding right now. The single derivation behind both the claim's
  held-ref bypass and the heartbeat's release reconciliation.
  """
  def active_held_refs(held) when is_list(held) do
    for %{"ref" => ref, "state" => state} <- held, state in @active_holding_states, do: ref
  end

  def active_held_refs(_held), do: []
end
