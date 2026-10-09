defmodule Storybook.FlowSettingsComponents.CopyFlowPanel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowSettingsComponents.copy_flow_panel/1
  def render_source, do: :function

  # The Copy to another stage… picker under a stage's FLOW band (RE431, card mockup "A — stage
  # row owns its flow"). Only free work stages are offered; the copy's key is previewed.
  @flow struct(Schemas.Flow, %{id: 1, key: "code", enabled: true, version: 4, nodes: []})

  defp form(stage_id), do: Phoenix.Component.to_form(%{"stage_id" => stage_id}, as: :copy)

  def variations do
    [
      %Variation{
        id: :two_targets,
        description: "Two free work stages — QA selected",
        attributes: %{
          flow: @flow,
          form: form(22),
          targets: [%{id: 21, name: "Deploy"}, %{id: 22, name: "QA"}],
          copy_key: "code-qa"
        }
      },
      %Variation{
        id: :one_target,
        description: "One free work stage",
        attributes: %{
          flow: @flow,
          form: form(21),
          targets: [%{id: 21, name: "Deploy"}],
          copy_key: "code-deploy"
        }
      }
    ]
  end
end
