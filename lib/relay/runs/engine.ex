defmodule Relay.Runs.Engine do
  @moduledoc """
  Pure routing logic for the runs engine (ADR 0006 card 02): `decide/4`
  maps a just-finalized node outcome to the run's next move. Every cap is
  derived from the outcome-bearing execution history, so the engine is
  restart-safe by construction and unit-testable with no DB or processes.

  `history` is every outcome-bearing (`outcome != nil`) execution of the
  run in insertion order, INCLUDING `current` (the just-finalized one).
  Abandoned/revoked attempts (`outcome` nil) never appear, so they never
  count against `max_retries`, `max_loops`, the visit cap, or the breaker.
  Rows may be `Schemas.NodeExecution` structs or plain maps with
  `node_key`/`visit`/`outcome`/`failure_signature`.

  `opts[:bonus]` (default 0, RLY-189) is added to EVERY cap this module
  consults — the node's `max_retries`, the edge's `max_loops` (only when the
  edge declares one; `nil` stays unlimited), the breaker threshold, and the
  visit cap. It is the run's human-retry count, so a retried run can always
  make exactly one more move than it just did without any counter being
  reset. The engine stays pure: it receives the number, it never reads the
  run.
  """

  alias Schemas.Flow

  require Logger

  @default_breaker_threshold 3
  @default_visit_cap 20

  @type decision ::
          {:transition, String.t()}
          | {:retry, String.t()}
          | {:park, :needs_input}
          | {:finish, :done}
          | {:fail, String.t()}

  @doc """
  Decides the run's next move, in rule order:

    1. `needs_input` parks — no edge is consulted.
    2. The failure-signature circuit breaker: >= `breaker_threshold` failed
       executions sharing `current`'s signature fail the run even when
       retries/loops technically remain (catches same-error loops across
       different edges/nodes).
    3. Retry: failed-outcome count in the current visit (including
       `current`) <= the node's `max_retries` (nil => 0) re-enters the
       same node.
    4. Route on the unique `{from, on}` edge. An outcome with NO matching edge
       degrades onto the node's `:failed` edge (RLY-179) and follows it exactly
       as a real `:failed` would, including its `max_loops` budget; only an
       unrouted `:failed` — nowhere left to fall back to — fails the run. A
       `gate` failure with no `failed` edge still fails, never silently passes.
       An edge past its `max_loops` (nil => unlimited) fails the run; target
       `"done"` finishes; a target at the visit cap fails the run (the backstop
       under unlimited loops).

  Under a `foreach`, budgets are accounted PER ITERATION: `opts[:sub_task_id]`
  filters the history before `max_loops` and the visit cap are counted, so a
  churny task cannot spend a later task's budget. (`max_retries` also receives
  the scoped history, but is a no-op either way — `retry_budget_left?/3`
  further filters by `visit`, which a real run never reuses across
  iterations, so the sub_task_id filter never changes its count.) The
  failure-signature breaker keeps the FULL history on purpose — per-iteration
  budgets bound productive churn, the breaker catches unproductive repetition,
  which is more alarming across iterations, not less. `sub_task_id: nil` makes
  the filter the identity function, so every node outside a `foreach` behaves
  exactly as it did before W13. `opts[:foreach_remaining]` (default 0) is the
  guard input, computed by RunServer — the engine stays pure.
  """
  @spec decide(Flow.t(), [map()], map(), keyword()) :: decision()
  def decide(%Flow{} = flow, history, current, opts \\ []) do
    bonus = Keyword.get(opts, :bonus, 0)
    breaker_threshold = Keyword.get(opts, :breaker_threshold, @default_breaker_threshold) + bonus
    scoped = scope_to_iteration(history, Keyword.get(opts, :sub_task_id))

    cond do
      current.outcome == :needs_input ->
        {:park, :needs_input}

      # The breaker gets the FULL, unfiltered history — deliberately (see @moduledoc).
      current.outcome == :failed and breaker_tripped?(history, current, breaker_threshold) ->
        {:fail, "circuit_breaker: the same failure repeated #{breaker_threshold} times"}

      current.outcome == :failed and retry_budget_left?(flow, scoped, current, bonus) ->
        {:retry, current.node_key}

      true ->
        route(flow, scoped, current, opts, bonus)
    end
  end

  # Iteration scoping: nil (any node outside a foreach) is the IDENTITY function,
  # so those nodes keep whole-run budgets exactly as before. Map.get, not the dot
  # access, because history rows may be plain maps in tests.
  defp scope_to_iteration(history, nil), do: history
  defp scope_to_iteration(history, id), do: Enum.filter(history, &(Map.get(&1, :sub_task_id) == id))

  @doc """
  SHA-1 signature of a normalized failure detail (trimmed, truncated to
  500 chars) — the circuit breaker's identity for "the same failure".
  Not a security control; SHA-1 is fine here.
  """
  def failure_signature(detail) do
    normalized = detail |> to_string() |> String.trim() |> String.slice(0, 500)
    Base.encode16(:crypto.hash(:sha, normalized), case: :lower)
  end

  defp breaker_tripped?(history, %{failure_signature: signature}, threshold) when is_binary(signature) do
    Enum.count(history, &(&1.outcome == :failed and &1.failure_signature == signature)) >= threshold
  end

  defp breaker_tripped?(_history, _current, _threshold), do: false

  # Failed count in the CURRENT visit including the current failure:
  # max_retries 1 => attempt 1's failure retries (1 <= 1), attempt 2's does
  # not (2 > 1).
  defp retry_budget_left?(flow, history, current, bonus) do
    failed =
      Enum.count(
        history,
        &(&1.node_key == current.node_key and &1.visit == current.visit and &1.outcome == :failed)
      )

    failed <= node_max_retries(flow, current.node_key) + bonus
  end

  defp node_max_retries(flow, node_key) do
    case Enum.find(flow.nodes, &(&1.key == node_key)) do
      %{max_retries: retries} when is_integer(retries) -> retries
      _missing_or_nil -> 0
    end
  end

  defp route(flow, history, current, opts, bonus) do
    remaining = Keyword.get(opts, :foreach_remaining, 0)
    visit_cap = Keyword.get(opts, :visit_cap, @default_visit_cap) + bonus

    case select_edge(flow, current, remaining) do
      nil -> degrade_to_failed(flow, history, current, remaining, visit_cap, bonus)
      edge -> follow(flow, edge, history, visit_cap, bonus)
    end
  end

  # RLY-179: an outcome the node declares no edge for is not automatically fatal.
  # Fall back to the node's `:failed` edge and follow it EXACTLY as a real `:failed`
  # would — same guard preference, same `max_loops` accounting (see
  # `effective_outcome/3`, which is what stops the degrade buying extra budget).
  # A `:failed` that is itself unrouted has nowhere left to fall back to, so it fails.
  defp degrade_to_failed(_flow, _history, %{outcome: :failed} = current, _remaining, _visit_cap, _bonus) do
    {:fail, no_route_reason(current)}
  end

  defp degrade_to_failed(flow, history, current, remaining, visit_cap, bonus) do
    case select_edge(flow, %{node_key: current.node_key, outcome: :failed}, remaining) do
      nil ->
        {:fail, no_route_reason(current)}

      edge ->
        Logger.warning(
          "run engine: node #{current.node_key} reported #{current.outcome}, which has no edge — " <>
            "degrading onto its :failed edge #{edge.from} → #{edge.to} (RLY-179)"
        )

        follow(flow, edge, history, visit_cap, bonus)
    end
  end

  # All {from, on} candidates: the first whose guard is SATISFIED wins, else the
  # unguarded one. Schemas.Flow guarantees at most one unguarded edge per route.
  defp select_edge(flow, current, remaining) do
    candidates = Enum.filter(flow.edges, &(&1.from == current.node_key and &1.on == current.outcome))

    Enum.find(candidates, &guard_satisfied?(&1, remaining)) || Enum.find(candidates, &is_nil(&1.when))
  end

  defp guard_satisfied?(%{when: :foreach_remaining}, remaining), do: remaining > 0
  defp guard_satisfied?(%{when: :foreach_exhausted}, remaining), do: remaining == 0
  defp guard_satisfied?(_unguarded, _remaining), do: false

  defp follow(flow, edge, history, visit_cap, bonus) do
    cond do
      loop_budget_exhausted?(flow, edge, history, bonus) ->
        {:fail, loop_budget_reason(edge)}

      edge.to == "done" ->
        {:finish, :done}

      visit_count(history, edge.to) >= visit_cap ->
        {:fail, visit_cap_reason(edge, visit_cap)}

      true ->
        {:transition, edge.to}
    end
  end

  # Prior traversals of this edge = outcome-bearing executions of `from` whose
  # EFFECTIVE outcome routes along it, minus the current one (history includes
  # current, and current always routes along the edge we just selected — directly
  # or by degrade — so the -1 is unconditional).
  defp loop_budget_exhausted?(_flow, %{max_loops: nil}, _history, _bonus), do: false

  defp loop_budget_exhausted?(flow, edge, history, bonus) do
    prior =
      Enum.count(history, fn row ->
        row.node_key == edge.from and effective_outcome(flow, edge.from, row.outcome) == edge.on
      end) - 1

    prior >= edge.max_loops + bonus
  end

  # The outcome an execution ACTUALLY routes on, after the RLY-179 degrade rule:
  # its own outcome when the node declares an edge for it, else `:failed`. Loop
  # accounting reads history through this, so a degraded traversal spends the
  # `:failed` edge's budget instead of resetting it. `:needs_input` parks before
  # routing is ever reached, so it never degrades.
  defp effective_outcome(_flow, _node_key, :needs_input), do: :needs_input

  defp effective_outcome(flow, node_key, outcome) do
    if Enum.any?(flow.edges, &(&1.from == node_key and &1.on == outcome)), do: outcome, else: :failed
  end

  # Failure reasons are human-first with the machine token retained in parentheses:
  # the sentence is what lands on the card in front of a person, the token is what
  # tests and grep-based diagnosis match on. Do not reword the parentheticals.
  defp no_route_reason(current) do
    "The flow has nowhere to go after `#{current.node_key}` reported `#{current.outcome}`. " <>
      "(no_route_for_outcome: #{current.node_key} → #{current.outcome})"
  end

  defp loop_budget_reason(edge) do
    "`#{edge.from}` looped back to `#{edge.to}` too many times without getting past it. " <>
      "(loop_budget_exhausted: #{edge.from} → #{edge.to} on #{edge.on} (max_loops #{edge.max_loops}))"
  end

  defp visit_cap_reason(edge, visit_cap) do
    "The flow kept returning to `#{edge.to}` — it has been visited #{visit_cap} times, the run's cap. " <>
      "(visit_cap_exceeded: #{edge.to} visited #{visit_cap} times)"
  end

  # A "visit" is any distinct visit number holding at least one
  # outcome-bearing execution — abandoned visits never count.
  defp visit_count(history, node_key) do
    history
    |> Enum.filter(&(&1.node_key == node_key))
    |> Enum.map(& &1.visit)
    |> Enum.uniq()
    |> length()
  end
end
