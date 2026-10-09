defmodule RelayWeb.Api.StageJSON do
  @moduledoc """
  JSON for the `/api/stages` routes — every stage rendered by `CardJSON.stage/3`, with the
  board's `ai_stage_ids` (`Relay.Flows.ai_stage_ids/1`) passed in by the controller, plus the
  read-only `"problem"` (RE430) from the controller's `stage_problems` map — `nil` unless the
  stage's enabled flow is paused on a broken board shape. Only these routes carry `problem`;
  `CardJSON.stage/3` (card and board responses) does not.
  """

  alias RelayWeb.Api.CardJSON

  def index(%{stages: stages, ai_stage_ids: ai_stage_ids, stage_problems: problems}),
    do: %{data: Enum.map(stages, &stage(&1, stages, ai_stage_ids, problems))}

  # A single stage resolves a substage's parent through `CardJSON.stage/3`'s fallback lookup.
  def show(%{stage: stage, ai_stage_ids: ai_stage_ids, stage_problems: problems}),
    do: %{data: stage(stage, [], ai_stage_ids, problems)}

  defp stage(stage, stages, ai_stage_ids, problems),
    do: stage |> CardJSON.stage(stages, ai_stage_ids) |> Map.put(:problem, Map.get(problems, stage.id))

  def lane(%{lane: lane, disabled: disabled}), do: %{data: %{lane: lane, disabled: disabled}}
end
