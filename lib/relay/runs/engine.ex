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
  """

  alias Schemas.Flow

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
    4. Route on the unique `{from, on}` edge. No edge fails the run for
       EVERY outcome — a `gate` failure with no `failed` edge fails,
       never silently passes. An edge past its `max_loops` (nil =>
       unlimited) fails the run; target `"done"` finishes; a target at
       the visit cap fails the run (the backstop under unlimited loops).
  """
  @spec decide(Flow.t(), [map()], map(), keyword()) :: decision()
  def decide(%Flow{} = flow, history, current, opts \\ []) do
    breaker_threshold = Keyword.get(opts, :breaker_threshold, @default_breaker_threshold)
    visit_cap = Keyword.get(opts, :visit_cap, @default_visit_cap)

    cond do
      current.outcome == :needs_input ->
        {:park, :needs_input}

      current.outcome == :failed and breaker_tripped?(history, current, breaker_threshold) ->
        {:fail, "circuit_breaker: the same failure repeated #{breaker_threshold} times"}

      current.outcome == :failed and retry_budget_left?(flow, history, current) ->
        {:retry, current.node_key}

      true ->
        route(flow, history, current, visit_cap)
    end
  end

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
  defp retry_budget_left?(flow, history, current) do
    failed =
      Enum.count(
        history,
        &(&1.node_key == current.node_key and &1.visit == current.visit and &1.outcome == :failed)
      )

    failed <= node_max_retries(flow, current.node_key)
  end

  defp node_max_retries(flow, node_key) do
    case Enum.find(flow.nodes, &(&1.key == node_key)) do
      %{max_retries: retries} when is_integer(retries) -> retries
      _missing_or_nil -> 0
    end
  end

  defp route(flow, history, current, visit_cap) do
    case Enum.find(flow.edges, &(&1.from == current.node_key and &1.on == current.outcome)) do
      nil ->
        {:fail, "no_route_for_outcome: #{current.node_key} → #{current.outcome}"}

      edge ->
        follow(edge, history, current, visit_cap)
    end
  end

  defp follow(edge, history, current, visit_cap) do
    cond do
      loop_budget_exhausted?(edge, history, current) ->
        {:fail, "loop_budget_exhausted: #{edge.from} → #{edge.to} on #{edge.on} (max_loops #{edge.max_loops})"}

      edge.to == "done" ->
        {:finish, :done}

      visit_count(history, edge.to) >= visit_cap ->
        {:fail, "visit_cap_exceeded: #{edge.to} visited #{visit_cap} times"}

      true ->
        {:transition, edge.to}
    end
  end

  # Prior traversals = outcome-bearing executions of `from` with this
  # outcome BEFORE the current one (history includes current, hence -1).
  defp loop_budget_exhausted?(%{max_loops: nil}, _history, _current), do: false

  defp loop_budget_exhausted?(edge, history, current) do
    prior = Enum.count(history, &(&1.node_key == edge.from and &1.outcome == current.outcome)) - 1
    prior >= edge.max_loops
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
