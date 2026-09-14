defmodule Schemas.Runner do
  @moduledoc """
  A durable runner registration (ADR 0006 card 04): the developer machine
  that pulls node-jobs. Keyed uniquely on `{board_id, name}` and refreshed on
  every claim / runner heartbeat. `capacity` is the last-advertised
  **configured** slot count per isolation class (not a live free count — see
  `Relay.Runs.Capacity`), normalized to the closed set and stored STRING-keyed:
  `%{"shared_clean" => 3, "exclusive" => 1}`. Unknown classes never reach the
  row (RLY-201). **That guarantee now has a single enforcement point (RE311):**
  `RelayWeb.Api.NodeJobController` puts `capacity` on the upsert attrs from the
  HEARTBEAT action only — the claim's `capacity` is the runner's live FREE
  count and is passed to `Relay.Runs.claim_next_job/3` as an argument instead of
  being written here, so one column can no longer carry two meanings.
  `last_heartbeat` drives reclaim:
  a runner silent past `max(60s, 2 × interval)` is stale and its in-flight
  jobs are recovered. `capabilities` is the last-reported inventory of what this
  runner can resolve by name — `%{"agents" => [...], "skills" => [...]}` — or
  `nil` when it has never reported one (RLY-182). All fields are set
  programmatically by `Relay.Runs`.

  `version` is the `RUNNER_VERSION` the running `./relay` declares (RLY-184); `nil` means
  a runner predating that card, which `Relay.Runs.runner_outdated?/1` treats as behind.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Schemas.RunnerRateLimit

  @type t :: %__MODULE__{}

  schema "runners" do
    field :name, :string
    field :host, :string
    field :interval, :integer, default: 30
    field :capacity, :map, default: %{}
    # No default: nil means "never reported its inventory" and is deliberately distinct
    # from %{} ("reported, and empty"). Preflight branches on that difference.
    field :capabilities, :map
    # RE311: heartbeat-written, defaulting to [] rather than nil — unlike `capabilities`,
    # nothing branches on "never reported" here: a runner holding nothing and a runner
    # that has not said are the same thing for occupancy purposes, and [] keeps every reader
    # (chip count, tooltip, diagnosis) free of a nil case.
    field :held, {:array, :map}, default: []
    field :version, :integer
    field :last_heartbeat, :utc_datetime

    # RE320: nil = claiming normally (or a runner predating RE320). Heartbeat-written only; a
    # value whose `resets_at` has passed is treated as not paused by
    # `Relay.Runs.runner_rate_limited?/2` before the next beat clears it.
    embeds_one :rate_limit, RunnerRateLimit, on_replace: :delete

    belongs_to :board, Schemas.Board

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built runner row."
  def changeset(runner, attrs) do
    runner
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
    |> put_rate_limit(attrs)
    |> validate_required([:board_id, :name, :last_heartbeat])
    |> foreign_key_constraint(:board_id)
    |> unique_constraint([:board_id, :name], name: :runners_board_id_name_index)
  end

  # RE320: an embed cannot go through `cast/3`, and it is never user input —
  # `Relay.Runs.upsert_runner/2` passes an already-normalized `%Schemas.RunnerRateLimit{}` or nil.
  # An absent key leaves the embed untouched.
  defp put_rate_limit(changeset, %{rate_limit: rate_limit}), do: put_embed(changeset, :rate_limit, rate_limit)
  defp put_rate_limit(changeset, _attrs), do: changeset

  # RE311 — the closed set of per-card worktree states a runner can declare it HOLDS,
  # defined exactly once on this side and mirrored in `./relay`'s HOLDING_STATES, which the
  # runner contract fixture (`vocabulary.holding_states`) pins to this function. Strings,
  # not atoms: this vocabulary only ever arrives off the wire and is only ever compared to
  # wire values, so atomizing it would buy nothing and add a conversion at every use site.
  @holding_states ["bound", "retained", "running", "talk"]

  # The three that occupy an exclusive partition. `retained` is a failed run's leftover held
  # for post-mortem: it holds no partition, the runner evicts it on its own terms, and
  # `assign()` refuses it at full capacity — so offering work for a retained ref would produce
  # a claimed-then-rejected job.
  @active_holding_states ["bound", "running", "talk"]

  @doc """
  Every state a runner may declare for a held per-card worktree.

    * `running` — active worktree with a live job
    * `bound` — active worktree, no live job, awaiting its run's next node
    * `talk` — active worktree a talk turn is attached to
    * `retained` — a failed run's leftover, kept for post-mortem; holds no partition
  """
  def holding_states, do: @holding_states

  @doc "The subset of `holding_states/0` that occupies an exclusive partition."
  def active_holding_states, do: @active_holding_states

  # The most per-card worktrees one beat may declare. A runner holds one worktree per card
  # and its `max_worktrees` is small (single digits in practice, and `capacity.exclusive` is
  # what the board is told), so this is orders of magnitude above any honest runner — it
  # exists so a malformed or hostile beat cannot buy an unbounded query on the heartbeat's hot
  # path (`Runs.releasable_held/2`, `pool_used/3`), which every runner hits every interval.
  @held_limit 500

  @doc "The cap `normalize_held/1` applies to one beat's `held` list."
  def held_limit, do: @held_limit

  @doc """
  The one normalizer for the `held` wire field: a list of `%{"ref" => ref, "state" => state}`
  with a binary ref and a state in `holding_states/0`, truncated to `held_limit/0`. Everything
  else is DROPPED.

  Total by construction — any term in, a list out. Untrusted input degrades, never raises: a
  stray entry from an older or newer runner must not 500 the claim or the heartbeat, which
  are that runner's liveness path (the RLY-201 lesson, applied to a second field).
  """
  def normalize_held(held) when is_list(held) do
    for %{"ref" => ref, "state" => state} <- Enum.take(held, @held_limit),
        is_binary(ref),
        state in @holding_states,
        do: %{"ref" => ref, "state" => state}
  end

  def normalize_held(_held), do: []

  @doc """
  The refs whose declared state occupies an exclusive partition — the refs whose worktree the
  runner is genuinely holding right now. The single derivation behind both the claim's
  held-ref bypass and the heartbeat's release reconciliation.
  """
  def active_held_refs(held) when is_list(held) do
    for %{"ref" => ref, "state" => state} <- held, state in @active_holding_states, do: ref
  end

  def active_held_refs(_held), do: []

  # RE320 — the closed sets on a runner's self-reported usage pause, defined once here and
  # mirrored in `./relay`'s RATE_LIMIT_WINDOWS / RATE_LIMIT_REASONS, which the runner contract
  # fixture (`vocabulary.rate_limit_windows` / `vocabulary.rate_limit_reasons`) pins to these
  # functions. Strings for the same reason as `@holding_states`: wire-only values.
  @rate_limit_windows ["five_hour", "seven_day"]
  @rate_limit_reason_limit "limit"
  @rate_limit_reason_rejected "rejected"
  @rate_limit_reasons [@rate_limit_reason_limit, @rate_limit_reason_rejected]

  @doc "The Claude usage windows a runner can pause on."
  def rate_limit_windows, do: @rate_limit_windows

  @doc """
  Why a runner paused: `limit` (a window reached its configured max) or `rejected` (Claude
  refused a call outright, which pauses a runner even with no limit configured).
  """
  def rate_limit_reasons, do: @rate_limit_reasons

  @doc "Whether a rate limit came from Claude refusing a call rather than a configured limit."
  def rejected_rate_limit?(%{reason: reason}), do: reason == @rate_limit_reason_rejected

  @doc """
  The one normalizer for the heartbeat's `rate_limit` wire field:
  `%{"window", "utilization", "max", "resets_at" (unix seconds), "reason"}` →
  `%Schemas.RunnerRateLimit{}`, or `nil` for anything it does not recognise (including a
  JSON null).

  Total by construction, like `normalize_held/1`: the heartbeat is the runner's liveness path,
  so an unknown window or reason from a newer runner degrades to "not paused" rather than 500ing.
  """
  def normalize_rate_limit(%{"window" => window, "reason" => reason, "resets_at" => resets_at} = wire)
      when window in @rate_limit_windows and reason in @rate_limit_reasons do
    with true <- is_integer(resets_at) and resets_at > 0,
         {:ok, at} <- DateTime.from_unix(resets_at),
         {:ok, utilization} <- fraction(Map.get(wire, "utilization")),
         {:ok, max} <- fraction(Map.get(wire, "max")) do
      %RunnerRateLimit{window: window, utilization: utilization, max: max, resets_at: at, reason: reason}
    else
      _invalid -> nil
    end
  end

  def normalize_rate_limit(_wire), do: nil

  defp fraction(nil), do: {:ok, nil}
  defp fraction(value) when is_number(value) and value >= 0, do: {:ok, value / 1}
  defp fraction(_value), do: :error
end
