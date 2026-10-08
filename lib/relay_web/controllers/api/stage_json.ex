defmodule RelayWeb.Api.StageJSON do
  @moduledoc """
  JSON for the `/api/stages` routes — every stage rendered by `CardJSON.stage/3`, with the
  board's `ai_stage_ids` (`Relay.Flows.ai_stage_ids/1`) passed in by the controller.
  """

  alias RelayWeb.Api.CardJSON

  def index(%{stages: stages, ai_stage_ids: ai_stage_ids}),
    do: %{data: Enum.map(stages, &CardJSON.stage(&1, stages, ai_stage_ids))}

  # A single stage resolves a substage's parent through `CardJSON.stage/3`'s fallback lookup.
  def show(%{stage: stage, ai_stage_ids: ai_stage_ids}), do: %{data: CardJSON.stage(stage, [], ai_stage_ids)}

  def lane(%{lane: lane, disabled: disabled}), do: %{data: %{lane: lane, disabled: disabled}}
end
