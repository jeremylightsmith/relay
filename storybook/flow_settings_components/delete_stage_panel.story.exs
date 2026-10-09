defmodule Storybook.FlowSettingsComponents.DeleteStagePanel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowSettingsComponents.delete_stage_panel/1
  def render_source, do: :function

  # The inline confirm a stage row's × opens on Board Settings → Stages (RE431, card mockup
  # "A — stage row owns its flow"). The flow is a literal struct: the panel reads key / version /
  # nodes only.
  @deploy %{id: 13, name: "Deploy"}
  @flow struct(Schemas.Flow, %{id: 3, key: "deploy", version: 6, nodes: Enum.map(1..4, &%{key: "n#{&1}"})})

  def variations do
    [
      %Variation{
        id: :with_flow,
        description: "A stage holding a flow — the panel names the flow it also deletes",
        attributes: %{stage: @deploy, flow: @flow}
      },
      %Variation{
        id: :without_flow,
        description: "A stage with no flow — a plain confirm",
        attributes: %{stage: %{id: 14, name: "Next up"}}
      },
      %Variation{
        id: :refusal,
        description: "Confirm was refused — the reason shows inside the panel",
        attributes: %{
          stage: %{id: 11, name: "Code"},
          flow: struct(Schemas.Flow, %{id: 1, key: "code", version: 4, nodes: Enum.map(1..7, &%{key: "n#{&1}"})}),
          error: "That stage still holds 1 live and 0 archived card(s) — move them out first."
        }
      }
    ]
  end
end
