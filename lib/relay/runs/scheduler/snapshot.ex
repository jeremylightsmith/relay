defmodule Relay.Runs.Scheduler.Snapshot do
  @moduledoc """
  The pure input to `Relay.Runs.Scheduler.plan/1`: a board's dispatch-relevant
  state as plain maps (no Ecto structs), so tests build fixtures freely and the
  core stays dependency-free.

    * `stages` — `[%{id, position, parent_id, wip_limit}]`. `parent_id` links a
      sub-lane to its column; `position` orders stages left→right; `wip_limit`
      is `nil` or a positive integer.
    * `cards` — `[%{id, ref, stage_id, status, active_owner, position}]`.
      `active_owner` is `:ai | :human | nil` (from `Relay.Cards.active_owner_type/1`).
    * `flows` — **enabled** flows only: `[%{key, pulls_from_stage_id,
      works_in_stage_id, isolation}]`; `isolation` is `:shared_clean | :exclusive`.
    * `runs` — **active** runs only (`status in Schemas.Run.active_statuses()`):
      `[%{id, card_id, status, flow_key, isolation, pinned_executor_id, parked_reason}]`.
      `parked_reason` is `nil | :needs_input | :claimed | :executor_gone` — only a
      `:executor_gone` park is the scheduler's to resume; `:needs_input` and `:claimed`
      parks are the run `Listener`'s territory (RLY-200).
    * `capacity` — `%{executor_id => %{shared_clean: n, exclusive: n}}`: the
      **free** slots each connected executor advertises per isolation class.
    * `executors` — `%{executor_id => %{name, version, outdated, freshness}}`: the durable
      executor rows, `outdated` from `Relay.Runs.executor_outdated?/1` and `freshness` from
      `Relay.Runs.executor_freshness/2` (not a second computation). `plan/1` ignores this
      field; only `explain/2` / `capacity_diagnosis/1` read it, so the plan/explain agreement
      property is unaffected.
  """

  @type stage :: %{
          id: term(),
          position: integer(),
          parent_id: term() | nil,
          wip_limit: pos_integer() | nil
        }
  @type card :: %{
          id: term(),
          ref: String.t() | nil,
          stage_id: term(),
          status: atom(),
          active_owner: :ai | :human | nil,
          position: integer()
        }
  @type flow :: %{
          key: String.t(),
          pulls_from_stage_id: term(),
          works_in_stage_id: term(),
          isolation: :shared_clean | :exclusive
        }
  @type run :: %{
          id: term(),
          card_id: term(),
          status: :running | :parked,
          flow_key: String.t(),
          isolation: :shared_clean | :exclusive,
          pinned_executor_id: term() | nil,
          parked_reason: :needs_input | :claimed | :executor_gone | nil
        }
  @type capacity :: %{optional(term()) => %{shared_clean: non_neg_integer(), exclusive: non_neg_integer()}}
  @type executor_status :: %{
          name: String.t(),
          version: integer() | nil,
          outdated: boolean(),
          freshness: :fresh | :stale | :gone
        }

  @type t :: %__MODULE__{
          stages: [stage()],
          cards: [card()],
          flows: [flow()],
          runs: [run()],
          capacity: capacity(),
          executors: %{optional(term()) => executor_status()}
        }

  defstruct stages: [], cards: [], flows: [], runs: [], capacity: %{}, executors: %{}
end
