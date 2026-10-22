defmodule RelayWeb.Api.SetupJSON do
  @moduledoc """
  Renders a board's setup checklist (`Relay.Setup.checklist/1`) for `GET /api/setup` and
  `POST /api/setup/steps/:step` (RE445). `current` is `Relay.Setup.reportable_id/1` — the one step
  a report may move; the interview catalog, the 5.4 change decisions and the 5.4 missing-file
  resolutions ride along so `./relay setup` and the skill never re-type them.

  `referenced_files` (RE447) is `Relay.Flows.referenced_files/1` over the board's flows — every
  `.claude/` agent or skill file they name, with its repo `paths` and the `{flow, node}` pairs
  using it (`[]` when the flows name none, as on every template board). `/relay-onboard` checks
  them at 5.1 and resolves the missing ones at 5.4.

  Statuses, actors and file kinds are strings, datetimes ISO 8601 or null. The step-3 key's raw
  token is never stored, so it can't appear here. `connect` is true for a connected machine's
  checklist (RE446): the skill runs its pull-only onboard.
  """

  alias Relay.Setup

  def show(%{checklist: checklist, board: board, referenced_files: referenced_files}) do
    %{
      data: %{
        board: board.name,
        connect: checklist.connect?,
        template: checklist.template,
        llm: Map.take(checklist.llm, [:harness, :label, :cli, :skill_dir, :skill_path, :pointer_file]),
        current_id: checklist.current_id,
        current_sub_id: checklist.current_sub_id,
        current: Setup.reportable_id(checklist),
        first_flow_stage: checklist.first_flow_stage,
        first_card_stage: checklist.first_card_stage,
        position: checklist.position,
        done_count: checklist.done_count,
        finished: checklist.finished?,
        interview: Setup.interview_questions(),
        change_decisions: Setup.change_decisions(),
        missing_file_resolutions: Setup.missing_file_resolutions(),
        referenced_files: Enum.map(referenced_files, &referenced_file/1),
        steps: Enum.map(checklist.steps, &step/1)
      }
    }
  end

  defp referenced_file(file), do: %{file | kind: Atom.to_string(file.kind)}

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
