defmodule Relay.Runs.RunDetail do
  @moduledoc """
  The run-visibility read model (RLY-207). Everything the drawer Run tab and
  the run-history entries need, derived ONCE in the domain from a run with its
  `node_executions` preloaded plus the run's flow — so the web layer renders it
  instead of re-folding raw executions. Pure: no `Repo` access.

  The forensics helpers here (`row_state/2`, `resumed?/2`, `synthetic_active/2`,
  `pending_tail/3`, `tripped_node/2`, `last_failure_detail/1`, `parked_attempt/2`,
  `type_tag/2`, `failure_reason/1`, timeline assembly) moved out of
  `RelayWeb.RunComponents` unchanged in behavior. Copy rule (ADR 0006):
  "session resumed" ONLY after a needs-input re-entry, never a review-failed loop.

  `run` fields are read by dot/`Map.get` access so both a `%Schemas.Run{}` and a
  plain test/story map work; `:node_executions` may be `nil` (treated as `[]`).
  """

  alias Schemas.Flow

  @type row :: map()
  @type t :: %__MODULE__{}

  defstruct [
    :status,
    :flow_key,
    :flow_version,
    :current_node,
    :last_node,
    :started_at,
    :finished_at,
    :breaker_tripped?,
    :tripped_node,
    :tripped_repeats,
    :failure_reason,
    :last_failure_detail,
    :parked_attempt,
    :totals,
    :timeline
  ]

  @doc "Builds the read model from a run (node_executions preloaded) and its flow (or nil)."
  def build(run, flow) do
    nes = Map.get(run, :node_executions) || []

    %__MODULE__{
      status: run.status,
      flow_key: Map.get(run, :flow_key),
      flow_version: Map.get(run, :flow_version),
      current_node: Map.get(run, :current_node),
      last_node: Relay.Runs.last_node(run, nes),
      started_at: Map.get(run, :started_at),
      finished_at: Map.get(run, :finished_at),
      breaker_tripped?: Relay.Runs.breaker_tripped?(run),
      tripped_node: tripped_node(run, nes),
      tripped_repeats: tripped_repeats(run, nes),
      failure_reason: failure_reason(run),
      last_failure_detail: last_failure_detail(nes),
      parked_attempt: parked_attempt(run, nes),
      totals: totals(nes),
      timeline: timeline(run, nes, flow)
    }
  end

  # ---- timeline (was RunComponents.timeline_rows/3) ----

  defp timeline(run, nes, flow) do
    node_rows =
      nes
      |> Enum.with_index()
      |> Enum.flat_map(fn {ne, index} ->
        prev = if index > 0, do: Enum.at(nes, index - 1)

        loop_row =
          if ne.attempt > 1 and prev != nil and prev.outcome == :failed do
            [
              %{
                kind: :loop,
                from_node: prev.node_key,
                to_node: ne.node_key,
                attempt: ne.attempt,
                max_loops: max_loops(prev, flow)
              }
            ]
          else
            []
          end

        loop_row ++ [node_row(ne, run, nes, flow)]
      end)

    node_rows ++ synthetic_active(run, nes) ++ pending_tail(run, nes, flow)
  end

  defp node_row(ne, run, nes, flow) do
    %{
      kind: :node,
      node_key: ne.node_key,
      attempt: ne.attempt,
      state: row_state(ne, run),
      resumed?: resumed?(ne, nes),
      partial?: ne.outcome == :partial,
      type: type_tag(ne.node_key, flow),
      detail: Map.get(ne, :detail),
      cost: Map.get(ne, :cost),
      duration_s: ne_duration_s(ne)
    }
  end

  # ---- row_state (was RunComponents.row_state/2), verbatim ----

  defp row_state(%{outcome: :succeeded}, _run), do: :done
  defp row_state(%{outcome: :partial}, _run), do: :done
  defp row_state(%{outcome: :failed}, _run), do: :failed
  defp row_state(%{outcome: :needs_input}, _run), do: :paused
  defp row_state(%{outcome: nil}, %{status: :running}), do: :active
  defp row_state(%{outcome: nil}, %{status: :parked}), do: :paused
  defp row_state(%{outcome: nil}, %{status: :failed}), do: :stopped
  defp row_state(%{outcome: nil}, _run), do: :cancelled

  # ---- resumed? (was RunComponents.resumed?/2), verbatim ----

  defp resumed?(%{attempt: attempt, node_key: node_key}, nes) when attempt > 1 do
    nes
    |> Enum.filter(&(&1.node_key == node_key and &1.attempt < attempt))
    |> List.last()
    |> case do
      %{outcome: :needs_input} -> true
      _other -> false
    end
  end

  defp resumed?(_ne, _nes), do: false

  # ---- loop max_loops (was baked into RunComponents.loop_text/3) ----

  defp max_loops(prev, %Flow{edges: edges}) do
    edge = Enum.find(edges, &(&1.from == prev.node_key and &1.on == :failed and &1.max_loops))
    edge && edge.max_loops
  end

  defp max_loops(_prev, _flow), do: nil

  # ---- type_tag (was RunComponents.type_tag/2), verbatim ----

  defp type_tag(node_key, %Flow{nodes: nodes}), do: Enum.find_value(nodes, fn n -> n.key == node_key && n.type end)

  defp type_tag(_node_key, _flow), do: nil

  # ---- synthetic_active (was RunComponents.synthetic_active/2), adjusted to the node-row shape ----

  defp synthetic_active(%{status: :running, current_node: node_key}, nes) when is_binary(node_key) do
    if Enum.any?(nes, &is_nil(&1.outcome)) do
      []
    else
      [
        %{
          kind: :node,
          node_key: node_key,
          attempt: 1,
          state: :active,
          resumed?: false,
          partial?: false,
          type: nil,
          detail: nil,
          cost: nil,
          duration_s: nil
        }
      ]
    end
  end

  defp synthetic_active(_run, _nes), do: []

  # ---- pending_tail (was RunComponents.pending_tail/3), returns node keys ----

  defp pending_tail(%{status: status} = run, nes, %Flow{} = flow) do
    if status in Schemas.Run.active_statuses() do
      executed = MapSet.new(nes, & &1.node_key)

      remaining =
        flow
        |> Relay.Runs.happy_path()
        |> Enum.reject(&(MapSet.member?(executed, &1) or &1 == Map.get(run, :current_node)))

      if remaining == [], do: [], else: [%{kind: :pending, nodes: remaining}]
    else
      []
    end
  end

  defp pending_tail(_run, _nes, _flow), do: []

  # ---- totals (was CoreComponents.run_totals/1) ----

  defp totals(nes) do
    %{
      duration_s: nes |> Enum.map(&ne_duration_s/1) |> Enum.reject(&is_nil/1) |> Enum.sum(),
      cost: sum_costs(Enum.map(nes, &Map.get(&1, :cost))),
      nodes: nes |> Enum.map(& &1.node_key) |> Enum.uniq() |> length(),
      attempts: length(nes)
    }
  end

  defp sum_costs(costs) do
    case Enum.reject(costs, &is_nil/1) do
      [] -> nil
      present -> Enum.reduce(present, Decimal.new(0), &Decimal.add/2)
    end
  end

  # ---- duration source (was RunComponents.ne_duration_s/1), verbatim ----

  defp ne_duration_s(%{duration_s: seconds}) when not is_nil(seconds), do: seconds
  defp ne_duration_s(%{started_at: s, finished_at: f}) when not is_nil(s) and not is_nil(f), do: DateTime.diff(f, s)
  defp ne_duration_s(_ne), do: nil

  # ---- failure forensics (was RunComponents.last_failure_detail/1, failure_reason/1,
  #      tripped_node/2, parked_attempt/2), verbatim ----

  defp last_failure_detail(nes) do
    nes
    |> Enum.filter(&(&1.outcome == :failed))
    |> List.last()
    |> then(&(&1 && &1.detail))
  end

  defp failure_reason(%{failure_detail: reason}) when is_binary(reason), do: reason
  defp failure_reason(_run), do: "The run stopped before reaching the end of the flow."

  defp tripped_node(run, nes) do
    nes
    |> Enum.filter(&(&1.outcome == :failed))
    |> List.last()
    |> case do
      %{node_key: node_key} -> node_key
      _other -> Map.get(run, :current_node)
    end
  end

  defp tripped_repeats(run, nes) do
    tripped = tripped_node(run, nes)
    Enum.count(nes, &(&1.node_key == tripped and &1.outcome == :failed))
  end

  defp parked_attempt(%{current_node: nil}, _nes), do: 1

  defp parked_attempt(%{current_node: node_key}, nes) do
    nes
    |> Enum.filter(&(&1.node_key == node_key))
    |> Enum.map(& &1.attempt)
    |> case do
      [] -> 1
      attempts -> Enum.max(attempts)
    end
  end

  defp parked_attempt(_run, _nes), do: 1
end
