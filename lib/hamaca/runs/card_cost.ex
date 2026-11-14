defmodule Hamaca.Runs.CardCost do
  @moduledoc """
  The card-cost read model (RE514). Folds a card's already-loaded runs — every run of every
  flow, newest first as `Hamaca.Runs.list_runs_for_card/1` returns them, `node_executions`
  preloaded — into the card's total, its unpriced count, an in-flight flag, one row per stage
  and the failed/cancelled row. Pure: no `Repo` access. `Hamaca.Runs.card_cost/1` is the public
  entry point; it supplies the set of agent execution ids, the one fact this module cannot read
  off the runs.

  `run` and execution fields are read by dot/`Map.get` access so both a `%Schemas.Run{}` and a
  plain test/story map work; `:node_executions` may be `nil` (treated as `[]`).

  The rules:

    1. **Total** — the sum of `cost` over every execution of every run: done, failed,
       cancelled, re-runs and the active run alike. A nil cost counts as $0.
    2. **Unpriced** — an execution that is finished (`finished_at` set), is an agent node (its id
       is in the agent set), is not `outcome: :blocked`, and has `cost: nil`. Counted across all
       runs, terminal ones included. Executions with no job and shell jobs are never unpriced; an
       in-flight execution is never unpriced.
    3. **In flight** — any run's status is in `Schemas.Run.active_statuses/0`.
    4. **Never priced** — when no execution has a non-nil cost, `build/2` returns nil.

  `by_stage` groups runs by `Hamaca.Runs.RunDetail.stage_label/1`, oldest stage first, and its
  costs sum to `total`. `failed` sums the `:failed` and `:cancelled` runs — a subset of the stage
  rows, never an extra addend — and is nil when there is none. Every `bar` is a 0..100 integer
  width against the largest stage cost (0 when that is zero); bars carry no percentages.
  """

  alias Hamaca.Runs.RunDetail
  alias Schemas.Run

  # The runs the failed row sums: a run that ended without finishing its flow.
  @failed_row_statuses [:failed, :cancelled]

  @type stage_row :: %{
          label: String.t(),
          runs: pos_integer(),
          failed: non_neg_integer(),
          cost: Decimal.t(),
          bar: 0..100
        }

  @type failed_row :: %{runs: pos_integer(), cost: Decimal.t(), bar: 0..100}

  @type t :: %{
          total: Decimal.t(),
          unpriced: non_neg_integer(),
          in_flight?: boolean(),
          runs: non_neg_integer(),
          by_stage: [stage_row()],
          failed: failed_row() | nil
        }

  @doc "Builds the card cost from its runs (newest first) and its agent execution ids; nil when nothing is priced."
  @spec build([map()], MapSet.t(integer())) :: t() | nil
  def build(runs, agent_ids) do
    executions = Enum.flat_map(runs, &executions/1)

    if Enum.any?(executions, &(&1.cost != nil)) do
      by_stage = by_stage(runs)
      max_cost = by_stage |> Enum.map(& &1.cost) |> Enum.max(Decimal, fn -> Decimal.new(0) end)

      %{
        total: sum(executions),
        unpriced: Enum.count(executions, &unpriced?(&1, agent_ids)),
        in_flight?: Enum.any?(runs, &Run.active?(&1.status)),
        runs: length(runs),
        by_stage: Enum.map(by_stage, &Map.put(&1, :bar, bar(&1.cost, max_cost))),
        failed: failed_row(runs, max_cost)
      }
    end
  end

  defp executions(run), do: Map.get(run, :node_executions) || []

  defp sum(executions), do: Enum.reduce(executions, Decimal.new(0), &Decimal.add(&1.cost || 0, &2))

  defp run_cost(run), do: run |> executions() |> sum()

  defp unpriced?(execution, agent_ids) do
    execution.cost == nil and Map.get(execution, :finished_at) != nil and
      Map.get(execution, :outcome) != :blocked and MapSet.member?(agent_ids, execution.id)
  end

  # Oldest stage first: walk the newest-first runs reversed and keep each label's first appearance.
  defp by_stage(runs) do
    oldest_first = Enum.reverse(runs)
    groups = Enum.group_by(oldest_first, &RunDetail.stage_label/1)

    oldest_first
    |> Enum.map(&RunDetail.stage_label/1)
    |> Enum.uniq()
    |> Enum.map(fn label ->
      label_runs = Map.fetch!(groups, label)

      %{
        label: label,
        runs: length(label_runs),
        failed: Enum.count(label_runs, &(&1.status == :failed)),
        cost: label_runs |> Enum.map(&run_cost/1) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      }
    end)
  end

  defp failed_row(runs, max_cost) do
    case Enum.filter(runs, &(&1.status in @failed_row_statuses)) do
      [] ->
        nil

      failed ->
        cost = failed |> Enum.map(&run_cost/1) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        %{runs: length(failed), cost: cost, bar: bar(cost, max_cost)}
    end
  end

  # Decimal throughout: 1.17 / 4.02 must round to exactly 29.
  defp bar(cost, max_cost) do
    if Decimal.eq?(max_cost, 0) do
      0
    else
      cost |> Decimal.div(max_cost) |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
    end
  end
end
