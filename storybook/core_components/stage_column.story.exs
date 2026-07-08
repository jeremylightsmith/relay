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
        id: :collapsed_empty,
        description: "An empty stage auto-collapses to the 44px dashed strip (MMF 12c)",
        attributes: %{
          id: "story-stage-collapsed",
          name: "Deploy",
          owner: :ai,
          stage_id: 6,
          count: 0,
          collapsed: true
        }
      },
      %Variation{
        id: :with_cards,
        attributes: %{
          id: "story-stage-code",
          name: "Code",
          owner: :ai,
          stage_id: 4,
          count: 2,
          category: :in_progress,
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
               tag: "ui",
               ref_number: 2,
               status: :queued,
               progress: nil,
               owners: []
             }}
          ]
        }
      },
      %Variation{
        id: :with_sublanes,
        attributes: %{
          id: "story-stage-code-sublanes",
          name: "Code",
          owner: :ai,
          stage_id: 4,
          count: 1,
          board_key: "RLY",
          cards: [
            {"story-card-3",
             %{
               title: "Wire up Google sign-in",
               tag: "auth",
               ref_number: 3,
               status: :working,
               progress: 61,
               owners: [%{actor_type: :agent}]
             }}
          ],
          category: :in_progress,
          sublanes: [
            %{
              id: 401,
              name: "Review",
              lane: :review,
              owner: :human,
              count: 1,
              cards: [
                {"story-card-4",
                 %{
                   title: "Approve the sign-in flow",
                   tag: nil,
                   ref_number: 4,
                   status: :in_review,
                   progress: nil,
                   owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}]
                 }}
              ]
            },
            %{id: 402, name: "Done", lane: :done, owner: :ai, count: 0, cards: []}
          ]
        }
      },
      %Variation{
        id: :with_collapsed_sublanes,
        description: "Empty Review/Done sub-lanes collapse to 34px strips (MMF 12c)",
        attributes: %{
          id: "story-stage-collapsed-sublanes",
          name: "Code",
          owner: :ai,
          stage_id: 5,
          count: 1,
          board_key: "RLY",
          category: :in_progress,
          cards: [
            {"story-card-5",
             %{
               title: "Implement the API",
               tag: "api",
               ref_number: 5,
               status: :working,
               progress: 30,
               owners: [%{actor_type: :agent}]
             }}
          ],
          sublanes: [
            %{id: 501, name: "Review", lane: :review, owner: :human, count: 0, cards: [], collapsed: true},
            %{id: 502, name: "Done", lane: :done, owner: :ai, count: 0, cards: [], collapsed: true}
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
