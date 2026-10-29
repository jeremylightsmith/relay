defmodule Schemas.Runner do
  @moduledoc """
  A durable runner registration (ADR 0006 card 04): the developer machine
  that pulls node-jobs. Keyed uniquely on `{board_id, name}` and refreshed on
  every claim / runner heartbeat. `capacity` is the last-advertised
  **configured** slot count per isolation class (not a live free count — see
  `Hamaca.Runs.Capacity`), normalized to the closed set and stored STRING-keyed:
  `%{"shared_clean" => 3, "exclusive" => 1}`. Unknown classes never reach the
  row (RLY-201). **That guarantee now has a single enforcement point (RE311):**
  `HamacaWeb.Api.NodeJobController` puts `capacity` on the upsert attrs from the
  HEARTBEAT action only — the claim's `capacity` is the runner's live FREE
  count and is passed to `Hamaca.Runs.claim_next_job/3` as an argument instead of
  being written here, so one column can no longer carry two meanings.
  `last_heartbeat` drives reclaim:
  a runner silent past `max(60s, 2 × interval)` is stale and its in-flight
  jobs are recovered. `capabilities` is the last-reported inventory of what this
  runner can resolve by name — `%{"agents" => [...], "skills" => [...]}` — or
  `nil` when it has never reported one (RLY-182). All fields are set
  programmatically by `Hamaca.Runs`.

  `version` is the `RUNNER_VERSION` the running `./relay` declares (RLY-184); `nil` means
  a runner predating that card, which `Hamaca.Runs.runner_outdated?/1` treats as behind.

  `cli` is the name the runner runs as — `"hamaca"` or `"relay"` (`cli_names/0`) — reported on
  every claim and heartbeat since RE478 and stored through `normalize_cli/1` (RE486): an unknown
  value, or none, is nil. `Hamaca.Runs.pre_rename_runner?/1` reads it to tell a runner still
  installed as `./relay` during the rename's compatibility window.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Schemas.HarnessUsage

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

    # RE337: card refs a human asked this runner to release — free the worktree and its slot while
    # the run stays parked. Never cast: `Hamaca.Runs.request_worktree_release/4` appends and
    # `Hamaca.Runs.upsert_runner/2` prunes, each with one atomic UPDATE, so a heartbeat and a click
    # can never overwrite each other.
    field :release_requests, {:array, :string}, default: []
    field :version, :integer
    # RE486: the CLI name the runner runs as, via `normalize_cli/1`. No default: nil means it
    # never reported one (pre-v94) or reported a name outside `cli_names/0`.
    field :cli, :string
    # RE433: the harness inventory the runner last reported on a heartbeat — see
    # `normalize_harnesses/1`. No default: nil means "never reported", which claims read as
    # "only the legacy harness" (`installed_harness_keys/1`). RE436: each entry carries that
    # harness's last usage reading; `Hamaca.Runs.active_rate_limit/2` reads the runner as rate
    # limited only when every installed harness is paused, and a pause whose `resets_at` has
    # passed reads as not paused before the next beat clears it.
    field :harnesses, {:array, :map}
    field :last_heartbeat, :utc_datetime

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
      :harnesses,
      :version,
      :cli,
      :last_heartbeat
    ])
    |> validate_required([:board_id, :name, :last_heartbeat])
    |> foreign_key_constraint(:board_id)
    |> unique_constraint([:board_id, :name], name: :runners_board_id_name_index)
  end

  # RE311 — the closed set of per-card worktree states a runner can declare it HOLDS,
  # defined exactly once on this side and mirrored in `./relay`'s HOLDING_STATES, which the
  # runner contract fixture (`vocabulary.holding_states`) pins to this function. Strings,
  # not atoms: this vocabulary only ever arrives off the wire and is only ever compared to
  # wire values, so atomizing it would buy nothing and add a conversion at every use site.
  @bound "bound"
  @retained "retained"
  @running "running"
  @talk "talk"

  @holding_states [@bound, @retained, @running, @talk]

  # The three that occupy an exclusive partition. `retained` is a failed run's leftover held
  # for post-mortem: it holds no partition, the runner evicts it on its own terms, and
  # `assign()` refuses it at full capacity — so offering work for a retained ref would produce
  # a claimed-then-rejected job.
  @active_holding_states [@bound, @running, @talk]

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

  # RE337 — a pending human release request survives a beat that reports its ref in one of these
  # states: `bound` (not yet sent, or sent and not yet acted on) and `talk` (the runner defers
  # teardown under a talk turn). Absent means the tree is gone; `running` means the run resumed
  # first — both clear the request, so a stale one can never tear down a resumed run's worktree.
  @release_pending_states [@bound, @talk]

  # RE337 — the status a human-requested release is sent with on `release_held`. The runner's
  # `_finish_locked` removes on anything but `failed` (which RETAINS), so this must be a remove
  # disposition; `cancelled` is also a real run status the runner already receives here.
  @release_remove_status :cancelled

  @doc "Whether a holding is idle — an active worktree with no live job, awaiting its run's next node."
  def idle_holding?(state), do: state == @bound

  @doc "Whether a pending release request survives a beat reporting its ref in `state` (RE337)."
  def release_request_pending?(state), do: state in @release_pending_states

  @doc "The remove disposition a human-requested release is sent with on `release_held` (RE337)."
  def release_remove_status, do: @release_remove_status

  @doc """
  Whether a human may release a holding's worktree (RE337): `:enabled` for an idle (`bound`)
  holding, `{:disabled, reason}` while a job or a talk turn occupies it, and `:hidden` for a
  `retained` tree, which holds no slot.
  """
  def release_eligibility(@bound), do: :enabled
  def release_eligibility(@running), do: {:disabled, "a job is running in this worktree"}
  def release_eligibility(@talk), do: {:disabled, "a talk session is attached"}
  def release_eligibility(@retained), do: :hidden

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

  # RE486 — the closed set of names a runner may run as, defined exactly once on this side and
  # mirrored in `./hamaca`'s CLI_NAMES, which the runner contract fixture (`runner.cli_names`)
  # pins to this function. Strings for the same reason as `@holding_states`: wire-only values.
  @cli_names ["hamaca", "relay"]

  @doc "Every name a runner may report as `runner.cli` — the current one first."
  @spec cli_names() :: [String.t()]
  def cli_names, do: @cli_names

  @doc """
  The one normalizer for the `runner.cli` wire field (RE486): the value when it is in
  `cli_names/0`, else nil. Total — untrusted input degrades, never raises.
  """
  @spec normalize_cli(term()) :: String.t() | nil
  def normalize_cli(cli) when cli in @cli_names, do: cli
  def normalize_cli(_cli), do: nil

  # RE320 — the closed set of reasons a harness pauses on a usage limit, defined once here and
  # mirrored in `./relay`'s USAGE_PAUSE_REASONS, which the runner contract fixture
  # (`vocabulary.rate_limit_reasons`) pins to this function. Strings for the same reason as
  # `@holding_states`: wire-only values. (RE436 retired the Claude-only window vocabulary — a
  # harness's usage rule names its own windows.)
  @rate_limit_reason_limit "limit"
  @rate_limit_reason_rejected "rejected"
  @rate_limit_reasons [@rate_limit_reason_limit, @rate_limit_reason_rejected]

  # RE436 — the most usage windows one harness reading may carry, and the most harness keys one
  # claim may narrow to. A harness defines a handful of windows and a board a handful of
  # harnesses; these only bound what a malformed or hostile request can make the hot path carry.
  @usage_window_limit 20
  @claim_harness_limit 50

  @doc """
  Why a harness paused: `limit` (a window reached its harness's PAUSE AT) or `rejected` (the
  harness refused a call outright, which pauses it even below PAUSE AT).
  """
  def rate_limit_reasons, do: @rate_limit_reasons

  @doc "Whether a pause came from the harness refusing a call rather than reaching PAUSE AT."
  def rejected_rate_limit?(%{reason: reason}), do: reason == @rate_limit_reason_rejected

  @doc """
  The one normalizer for the heartbeat's `harnesses` wire field (RE433): a list of
  `%{"key" => key, "installed" => boolean, "version" => string | nil, "signed_in" => boolean | nil,
  "usage" => usage | nil}`. An entry without a binary key and a boolean `installed` is DROPPED,
  and so is a malformed optional value (degraded to nil). A non-list is nil — "this beat did not
  report".

  RE436: `usage` is the harness's last usage reading, as the runner's per-harness limiter reports
  it:

      %{"source" => source, "read_at" => unix | nil,
        "windows" => [%{"label" => binary, "used_pct" => float, "resets_at" => unix}],
        "paused" => %{"label" => binary | nil, "used_pct" => float | nil, "pause_at" => 1..100 | nil,
                      "resets_at" => unix, "reason" => reason} | nil}

  `source` must be in `Schemas.HarnessUsage.sources/0`, else the whole reading is nil; a malformed
  window is dropped and at most #{@usage_window_limit} are kept; a malformed `paused` is nil, and
  its `reason` must be in `rate_limit_reasons/0`. The entry is kept either way.

  Total by construction, like `normalize_held/1`: the heartbeat is the runner's liveness path.
  """
  @spec normalize_harnesses(term()) :: [map()] | nil
  def normalize_harnesses(harnesses) when is_list(harnesses) do
    for %{"key" => key, "installed" => installed} = entry <- harnesses, is_binary(key), is_boolean(installed) do
      %{
        "key" => key,
        "installed" => installed,
        "version" => if(is_binary(entry["version"]), do: entry["version"]),
        "signed_in" => if(is_boolean(entry["signed_in"]), do: entry["signed_in"]),
        "usage" => normalize_usage(entry["usage"])
      }
    end
  end

  def normalize_harnesses(_harnesses), do: nil

  defp normalize_usage(%{"source" => source} = usage) when is_binary(source) do
    if source in HarnessUsage.sources() do
      %{
        "source" => source,
        "read_at" => unix_or_nil(usage["read_at"]),
        "windows" => normalize_usage_windows(usage["windows"]),
        "paused" => normalize_usage_paused(usage["paused"])
      }
    end
  end

  defp normalize_usage(_usage), do: nil

  defp normalize_usage_windows(windows) when is_list(windows) do
    windows
    |> Enum.flat_map(fn
      %{"label" => label, "used_pct" => used_pct, "resets_at" => resets_at}
      when is_binary(label) and is_number(used_pct) and is_integer(resets_at) and resets_at > 0 ->
        [%{"label" => label, "used_pct" => used_pct / 1, "resets_at" => resets_at}]

      _malformed ->
        []
    end)
    |> Enum.take(@usage_window_limit)
  end

  defp normalize_usage_windows(_windows), do: []

  defp normalize_usage_paused(%{"resets_at" => resets_at, "reason" => reason} = paused)
       when is_integer(resets_at) and resets_at > 0 and reason in @rate_limit_reasons do
    with {:ok, label} <- optional(paused["label"], &is_binary/1),
         {:ok, used_pct} <- optional(paused["used_pct"], &is_number/1),
         {:ok, pause_at} <- optional(paused["pause_at"], &(is_integer(&1) and &1 in 1..100)) do
      %{
        "label" => label,
        "used_pct" => used_pct && used_pct / 1,
        "pause_at" => pause_at,
        "resets_at" => resets_at,
        "reason" => reason
      }
    else
      :error -> nil
    end
  end

  defp normalize_usage_paused(_paused), do: nil

  defp optional(nil, _valid?), do: {:ok, nil}
  defp optional(value, valid?), do: if(valid?.(value), do: {:ok, value}, else: :error)

  defp unix_or_nil(at) when is_integer(at) and at > 0, do: at
  defp unix_or_nil(_at), do: nil

  @doc """
  The one normalizer for the claim's `harnesses` field (RE436): the harness keys the runner will
  run right now — its installed ones minus those paused at a usage limit. A list of binaries
  (anything else dropped), capped at #{@claim_harness_limit}; a non-list is nil, meaning "not
  narrowed". Request-scoped, like the claim's `held`: passed to `Hamaca.Runs.claim_next_job/4`,
  never written to the row.
  """
  @spec normalize_claim_harnesses(term()) :: [String.t()] | nil
  def normalize_claim_harnesses(keys) when is_list(keys),
    do: keys |> Enum.filter(&is_binary/1) |> Enum.take(@claim_harness_limit)

  def normalize_claim_harnesses(_keys), do: nil

  @doc "The keys of the harnesses the runner reported installed, or nil when it never reported (RE433)."
  @spec installed_harness_keys(t()) :: [String.t()] | nil
  def installed_harness_keys(%__MODULE__{harnesses: nil}), do: nil

  def installed_harness_keys(%__MODULE__{harnesses: harnesses}) do
    for %{"key" => key, "installed" => true} <- harnesses, do: key
  end

  @doc """
  The refs whose declared state occupies an exclusive partition — the refs whose worktree the
  runner is genuinely holding right now. The single derivation behind both the claim's
  held-ref bypass and the heartbeat's release reconciliation.
  """
  def active_held_refs(held) when is_list(held) do
    for %{"ref" => ref, "state" => state} <- held, state in @active_holding_states, do: ref
  end

  def active_held_refs(_held), do: []
end
