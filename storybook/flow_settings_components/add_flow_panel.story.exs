defmodule Storybook.FlowSettingsComponents.AddFlowPanel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowSettingsComponents.add_flow_panel/1
  def render_source, do: :function

  # The + Add flow panel inside a work stage's dashed no-flow band (RE431, card mockup "A —
  # stage row owns its flow"): a default-library flow not yet on the board, or a blank one.
  @qa %{id: 31, name: "QA"}
  @neighbours %{pulls_from: "Deploy", lands_on: "Done"}

  def variations do
    [
      %Variation{
        id: :library_available,
        description: "A library flow is missing from the board — start from it",
        attributes: %{
          stage: @qa,
          form: Phoenix.Component.to_form(%{"source" => "default", "default_key" => "code"}, as: :add),
          addable_defaults: ["code"],
          neighbours: @neighbours
        }
      },
      %Variation{
        id: :blank_only,
        description: "Every library flow is on the board — blank only",
        attributes: %{
          stage: @qa,
          form: Phoenix.Component.to_form(%{"source" => "blank", "default_key" => nil}, as: :add),
          addable_defaults: [],
          neighbours: @neighbours
        }
      }
    ]
  end
end
