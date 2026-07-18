defmodule Relay.Runs.Scheduler.Plan do
  @moduledoc """
  The pure output of `Relay.Runs.Scheduler.plan/1`.

    * `dispatches` — ordered highest-priority first; each is
      `{:resume, run_id, executor_id}` or `{:start, card_id, flow_key, executor_id}`.
      The equivalent of today's `find_all_ready` `chosen` list, now carrying a
      **named executor** per decision.
    * `to_queue` — `ready`/`queued` cards an enabled flow would pull but for which
      no capacity is free → the shell flips them to `:queued`.
    * `to_unqueue` — currently `:queued` cards no longer capacity-blocked (flow
      disabled, WIP filled, human-claimed) → the shell flips them back to `:ready`.
      A card being dispatched this pass is **not** unqueued (the engine sets `:working`).
  """

  @type dispatch ::
          {:resume, run_id :: term(), executor_id :: term()}
          | {:start, card_id :: term(), flow_key :: String.t(), executor_id :: term()}

  @type t :: %__MODULE__{
          dispatches: [dispatch()],
          to_queue: [term()],
          to_unqueue: [term()]
        }

  defstruct dispatches: [], to_queue: [], to_unqueue: []
end
