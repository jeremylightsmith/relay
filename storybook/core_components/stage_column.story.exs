defmodule Storybook.Components.CoreComponents.StageColumn do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.stage_column/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :empty_human,
        attributes: %{id: "story-stage-backlog", name: "Backlog", owner: :human, stage_id: 1, count: 0}
      },
      %Variation{
        id: :with_cards,
        attributes: %{
          id: "story-stage-code",
          name: "Code",
          owner: :ai,
          stage_id: 4,
          count: 2,
          board_key: "RLY",
          cards: [
            {"story-card-1",
             %{
               title: "Wire up Google sign-in",
               tag: "auth",
               ref_number: 1,
               status: :working,
               progress: 61,
               owners: [%{actor_type: :agent}]
             }},
            {"story-card-2",
             %{
               title: "Render the stage columns",
               tag: nil,
               ref_number: 2,
               status: :queued,
               progress: nil,
               owners: []
             }}
          ]
        }
      },
      %Variation{
        id: :composing,
        attributes: %{
          id: "story-stage-plan",
          name: "Plan",
          owner: :ai,
          stage_id: 3,
          composing: true,
          compose_form: Phoenix.Component.to_form(%{"title" => ""}, as: :card)
        }
      }
    ]
  end
end
