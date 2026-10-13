defmodule RelayWeb.Api.SetupJSON do
  @moduledoc """
  Renders a board's setup checklist (`Relay.Setup.checklist/1`) for `GET /api/setup` and
  `POST /api/setup/steps/:step` (RE445). `current` is `Relay.Setup.reportable_id/1` — the one step
  a report may move; the interview catalog and the 5.4 change decisions ride along so
  `./relay setup` and the skill never re-type them. Statuses and actors are strings, datetimes
  ISO 8601 or null. The step-3 key's raw token is never stored, so it can't appear here.
  """

  alias Relay.Setup

  def show(%{checklist: checklist, board: board}) do
    %{
      data: %{
        board: board.name,
        template: checklist.template,
        llm: Map.take(checklist.llm, [:harness, :label, :cli, :skill_path]),
        current_id: checklist.current_id,
        current_sub_id: checklist.current_sub_id,
        current: Setup.reportable_id(checklist),
        first_flow_stage: checklist.first_flow_stage,
        position: checklist.position,
        done_count: checklist.done_count,
        finished: checklist.finished?,
        interview: Setup.interview_questions(),
        change_decisions: Setup.change_decisions(),
        steps: Enum.map(checklist.steps, &step/1)
      }
    }
  end

  defp step(entry) do
    %{
      id: entry.id,
      parent: entry.parent,
      title: entry.title,
      actor: Atom.to_string(entry.actor),
      status: Atom.to_string(entry.status),
      evidence: entry.evidence,
      error: entry.error,
      data: entry.data,
      reached_at: entry.reached_at && DateTime.to_iso8601(entry.reached_at),
      completed_at: entry.completed_at && DateTime.to_iso8601(entry.completed_at),
      children: Enum.map(entry.children, &step/1)
    }
  end
end
