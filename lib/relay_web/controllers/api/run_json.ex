defmodule RelayWeb.Api.RunJSON do
  @moduledoc """
  Serializes runs and their node executions.

  **`detail` is emitted in full and is never truncated.** This is the single most
  important property of this surface: the text that gets cut is exactly the failing
  review's findings the operator went looking for (RLY-177). Any future "shorten long
  fields" change must exempt this.
  """

  alias Schemas.NodeExecution
  alias Schemas.Run

  def index(%{runs: runs}), do: %{data: Enum.map(runs, &run/1)}

  defp run(%Run{} = run) do
    %{
      id: run.id,
      flow_key: run.flow_key,
      status: run.status,
      parked_reason: run.parked_reason,
      current_node: run.current_node,
      failure_detail: run.failure_detail,
      started_at: run.started_at,
      finished_at: run.finished_at,
      node_executions: executions(run.node_executions)
    }
  end

  defp executions(executions) when is_list(executions), do: Enum.map(executions, &execution/1)
  defp executions(_not_loaded), do: []

  defp execution(%NodeExecution{} = e) do
    %{
      node_key: e.node_key,
      visit: e.visit,
      attempt: e.attempt,
      outcome: e.outcome,
      detail: e.detail,
      failure_signature: e.failure_signature,
      git_sha: e.git_sha,
      session_id: e.session_id,
      cost: e.cost,
      sub_task_id: e.sub_task_id,
      started_at: e.started_at,
      finished_at: e.finished_at
    }
  end
end
