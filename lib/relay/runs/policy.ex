defmodule Relay.Runs.Policy do
  @moduledoc """
  The single "may an agent work this card" gate (RLY-206) — pure predicates over the plain
  snapshot maps the scheduler already builds. One definition each for the human-baton gate, the
  fresh-pull gate, and the executor-gone resume gate, so the scheduler, the run listener, and the
  board card face can never drift from one another.

  Callers that hold a `Schemas.Card` (the listener, `Relay.Runs.queued_flow/4`) build the tiny
  map at the call site; the scheduler passes its snapshot maps straight through, so
  `Relay.Runs.Scheduler`'s tests double as this module's tests. Internal to the `Relay.Runs`
  boundary; not exported.
  """

  # The closed sets this module owns (RLY-206 / AGENTS.md "a magic value is defined once").
  @queueable_statuses [:ready, :queued]
  @blocked_card_statuses [:needs_input, :failed]

  @doc "The human-baton gate: an unowned (`nil`) or AI-owned card is agent-eligible; a human-owned one is not."
  @spec agent_may_hold?(%{active_owner: atom() | nil}) :: boolean()
  def agent_may_hold?(%{active_owner: owner}), do: owner != :human

  @doc "A fresh card the scheduler would pull: agent-eligible and in a queueable status (`:ready`/`:queued`)."
  @spec pullable?(%{active_owner: atom() | nil, status: atom()}) :: boolean()
  def pullable?(%{status: status} = card), do: agent_may_hold?(card) and status in @queueable_statuses

  @doc """
  The scheduler's `:executor_gone`-park resume gate (RLY-200): a parked run whose reason is
  `:executor_gone`, on an agent-held card that is not blocked (`:needs_input`) or dead
  (`:failed`). `:needs_input` / `:claimed` parks stay the run listener's territory.
  """
  @spec resumable?(%{status: atom(), parked_reason: atom() | nil}, %{
          active_owner: atom() | nil,
          status: atom()
        }) :: boolean()
  def resumable?(%{status: :parked, parked_reason: :executor_gone}, %{status: card_status} = card) do
    agent_may_hold?(card) and card_status not in @blocked_card_statuses
  end

  def resumable?(_run, _card), do: false
end
