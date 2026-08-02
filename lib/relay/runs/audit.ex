defmodule Relay.Runs.Audit do
  @moduledoc """
  Run-history health checks (RE249) — the half of `relay audit` whose data lives only in the
  server's database.

  `/relay-doctor`'s nine checks all ask "does this name resolve?", so a green doctor means
  "this flow can *start*", not "this board's history is clean". These checks ask the second
  question, from history the server already stores.

  Pure by construction: `findings/2` takes the flow and its runs with `:node_executions`
  preloaded and returns findings — no queries — which is what makes it testable from fixtures.
  `Relay.Runs.recent_runs_for_flow/2` does the loading and `Relay.Runs.audit/2` composes them.

  ## The checks

    * `:findings_dropped` (ERROR) — a node failed inside a `foreach` iteration, its `on: :failed`
      edge loops back to another node, and that node's next execution carried a DIFFERENT
      `sub_task_id`: the review's findings were never addressed and the cursor advanced anyway.
    * `:verdict_flipped` (WARNING; ERROR for every flip in a run where two distinct nodes
      flipped) — same node, same visit, same `git_sha`, `failed` on one attempt and `succeeded`
      on the next: a retry laundered a failure into a pass.

  Both are deliberately conservative. A missing subsequent execution, a nil `sub_task_id` or a
  nil `git_sha` produces NO finding: a false "your gates are lying" is worse than a miss.
  """

  alias Schemas.Flow
  alias Schemas.NodeExecution
  alias Schemas.Run

  # Ordered most severe first — `severity_rank/1` and every report's ordering read this list,
  # and it is pinned on the wire by test/fixtures/executor_contract.json.
  @severities [:error, :warning]
  @checks [:findings_dropped, :verdict_flipped]

  # Policy: one node getting lucky on a retry is noise; two distinct nodes flipping in one run
  # is a pattern, so every flip in that run escalates.
  @escalate_at_distinct_nodes 2

  @type finding :: %{
          severity: :error | :warning,
          check: :findings_dropped | :verdict_flipped,
          flow_key: String.t(),
          node_key: String.t() | nil,
          run_id: integer() | nil,
          summary: String.t(),
          evidence: String.t(),
          fix: String.t()
        }

  @doc "The closed set of finding severities, most severe first."
  def severities, do: @severities

  @doc "The closed set of run-history check ids."
  def checks, do: @checks

  @doc """
  Findings for `flow` over `runs` (each with `:node_executions` preloaded), errors first.

  Executions are ordered by `id` here rather than trusting the preload's order: both checks
  reason about "the next execution", so the order is part of the check, not of the query.
  """
  @spec findings(Flow.t(), [Run.t()]) :: [finding()]
  def findings(%Flow{} = flow, runs) when is_list(runs) do
    runs
    |> Enum.flat_map(fn run ->
      executions = Enum.sort_by(run.node_executions, & &1.id)
      dropped_findings(flow, run, executions) ++ flipped_findings(flow, run, executions)
    end)
    |> Enum.sort_by(&{severity_rank(&1.severity), &1.run_id, &1.check})
  end

  defp severity_rank(severity), do: Enum.find_index(@severities, &(&1 == severity))

  # ---- C1: findings dropped ------------------------------------------------

  defp dropped_findings(flow, run, executions) do
    executions
    |> Enum.with_index()
    |> Enum.flat_map(fn {execution, index} ->
      dropped_finding(flow, run, executions, execution, index)
    end)
  end

  defp dropped_finding(flow, run, executions, execution, index) do
    with true <- execution.outcome == :failed,
         true <- not is_nil(execution.sub_task_id),
         target when is_binary(target) <- loop_back_target(flow, execution.node_key),
         %NodeExecution{} = next <- next_execution_of(executions, index, target),
         true <- next.sub_task_id != execution.sub_task_id do
      [
        %{
          severity: :error,
          check: :findings_dropped,
          flow_key: flow.key,
          node_key: execution.node_key,
          run_id: run.id,
          summary:
            "node `#{execution.node_key}` failed on sub_task #{sub_task_label(execution.sub_task_id)}; " <>
              "the next `#{target}` execution carried sub_task #{sub_task_label(next.sub_task_id)} — " <>
              "findings were never addressed",
          evidence: "relay runs <ref> --json — run #{run.id}, executions #{execution.id} → #{next.id}",
          fix: "re-open that task and re-run it"
        }
      ]
    else
      _ -> []
    end
  end

  # A `failed` edge that returns to a NODE is a verdict that loops back; one that ends at a
  # sentinel (`done` / `needs_input`) is an error that stops the run, and stopping drops
  # nothing. Requiring the target to name a node says that without a second copy of the
  # sentinel list living here.
  defp loop_back_target(%Flow{} = flow, node_key) do
    keys = MapSet.new(flow.nodes || [], & &1.key)

    Enum.find_value(flow.edges || [], fn edge ->
      if edge.from == node_key and edge.on == :failed and MapSet.member?(keys, edge.to) do
        edge.to
      end
    end)
  end

  defp next_execution_of(executions, index, target) do
    executions |> Enum.drop(index + 1) |> Enum.find(&(&1.node_key == target))
  end

  defp sub_task_label(nil), do: "none"
  defp sub_task_label(id), do: Integer.to_string(id)

  # ---- C2: verdict flipped on retry ----------------------------------------

  defp flipped_findings(flow, run, executions) do
    flips =
      executions
      |> Enum.group_by(&{&1.node_key, &1.visit})
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {_group, attempts} ->
        attempts
        |> Enum.sort_by(& &1.attempt)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(&flip?/1)
      end)

    severity = flip_severity(flips)
    Enum.map(flips, &flip_finding(flow, run, severity, &1))
  end

  # Binding `sha` twice is what requires the commit to be UNCHANGED; `is_binary/1` is what makes
  # a nil sha produce no finding — without a sha there is no proof the code stood still.
  defp flip?([%NodeExecution{outcome: :failed, git_sha: sha}, %NodeExecution{outcome: :succeeded, git_sha: sha}])
       when is_binary(sha), do: true

  defp flip?(_pair), do: false

  defp flip_severity(flips) do
    distinct =
      flips |> Enum.map(fn [failed, _passed] -> failed.node_key end) |> Enum.uniq() |> length()

    if distinct >= @escalate_at_distinct_nodes, do: :error, else: :warning
  end

  defp flip_finding(flow, run, severity, [failed, passed]) do
    %{
      severity: severity,
      check: :verdict_flipped,
      flow_key: flow.key,
      node_key: failed.node_key,
      run_id: run.id,
      summary:
        "node `#{failed.node_key}` flipped failed → succeeded on retry at " <>
          "#{short_sha(failed.git_sha)} (visit #{failed.visit}) — the commit did not change " <>
          "between attempts",
      evidence: "relay runs <ref> --json — run #{run.id}, executions #{failed.id} → #{passed.id}",
      fix: "this gate's verdict is not reproducible — investigate before trusting it"
    }
  end

  defp short_sha(sha), do: String.slice(sha, 0, 7)
end
