defmodule RelayWeb.Api.StageJSON do
  @moduledoc "JSON for the `/api/stages` routes — every stage rendered by `CardJSON.stage/2`."

  alias RelayWeb.Api.CardJSON

  def index(%{stages: stages}), do: %{data: Enum.map(stages, &CardJSON.stage(&1, stages))}

  # A single stage resolves a substage's parent through `CardJSON.stage/2`'s fallback lookup.
  def show(%{stage: stage}), do: %{data: CardJSON.stage(stage, [])}

  def lane(%{lane: lane, disabled: disabled}), do: %{data: %{lane: lane, disabled: disabled}}
end
