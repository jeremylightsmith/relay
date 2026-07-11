defmodule Storybook.Components.CoreComponents.StageColumn do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.stage_column/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :empty_human,
        attributes: %{id: "story-stage-backlog", name: "Backlog", type: :queue, stage_id: 1, count: 0}
      },
      %Variation{
        id: :collapsed_empty,
        description: "An empty stage auto-collapses to the 44px dashed strip (MMF 12c)",
        attributes: %{
          id: "story-stage-collapsed",
          name: "Deploy",
          type: :work,
          ai_enabled: true,
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
          type: :work,
          ai_enabled: true,
          stage_id: 4,
          count: 2,
          category: :in_progress,
          board_key: "RLY",
          cards: [
            {"story-card-1",
             %{
               id: 1,
               title: "Wire up Google sign-in",
               tag: "auth",
               ref_number: 1,
               status: :working,
               progress: 61,
               owners: [%{actor_type: :agent}]
             }},
            {"story-card-2",
             %{
               id: 2,
               title: "Render the stage columns",
               tag: "ui",
               ref_number: 2,
               status: :ready,
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
          type: :work,
          ai_enabled: true,
          stage_id: 4,
          count: 1,
          board_key: "RLY",
          cards: [
            {"story-card-3",
             %{
               id: 3,
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
                   id: 4,
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
          type: :work,
          ai_enabled: true,
          stage_id: 5,
          count: 1,
          board_key: "RLY",
          category: :in_progress,
          cards: [
            {"story-card-5",
             %{
               id: 5,
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
          type: :planning,
          ai_enabled: true,
          stage_id: 3,
          composing: true,
          compose_form: Phoenix.Component.to_form(%{"title" => ""}, as: :card)
        }
      },
      %Variation{
        id: :wip_within_limit,
        description: "A WIP-limited stage within its limit shows the neutral wip chip (MMF 11)",
        attributes: %{
          id: "story-stage-wip-ok",
          name: "Code",
          type: :work,
          ai_enabled: true,
          stage_id: 7,
          count: 2,
          wip_limit: 3,
          category: :in_progress,
          board_key: "RLY",
          cards: [
            {"story-card-wip-1",
             %{
               id: 6,
               title: "Wire up Google sign-in",
               tag: "auth",
               ref_number: 6,
               status: :working,
               progress: 61,
               owners: [%{actor_type: :agent}]
             }},
            {"story-card-wip-2",
             %{
               id: 7,
               title: "Render the stage columns",
               tag: "ui",
               ref_number: 7,
               status: :ready,
               progress: nil,
               owners: []
             }}
          ]
        }
      },
      %Variation{
        id: :wip_over_limit,
        description: "Exceeding the limit flips the chip to the rose over-WIP treatment (MMF 11)",
        attributes: %{
          id: "story-stage-wip-over",
          name: "Code",
          type: :work,
          ai_enabled: true,
          stage_id: 8,
          count: 4,
          wip_limit: 3,
          category: :in_progress,
          board_key: "RLY",
          cards: [
            {"story-card-wip-3",
             %{
               id: 8,
               title: "Ship the WIP chip",
               tag: "ui",
               ref_number: 8,
               status: :working,
               progress: 40,
               owners: [%{actor_type: :agent}]
             }},
            {"story-card-wip-4",
             %{
               id: 9,
               title: "Fix the flaky deploy",
               tag: "infra",
               ref_number: 9,
               status: :ready,
               progress: nil,
               owners: []
             }},
            {"story-card-wip-5",
             %{
               id: 10,
               title: "Add the settings stepper",
               tag: nil,
               ref_number: 10,
               status: :working,
               progress: 15,
               owners: [%{actor_type: :agent}]
             }},
            {"story-card-wip-6",
             %{
               id: 11,
               title: "Write the move warning",
               tag: nil,
               ref_number: 11,
               status: :ready,
               progress: nil,
               owners: []
             }}
          ]
        }
      },
      %Variation{
        id: :type_queue,
        description: "queue — hollow rounded square (neutral)",
        attributes: %{id: "story-stage-type-queue", name: "Backlog", type: :queue, stage_id: 901, count: 3}
      },
      %Variation{
        id: :type_work,
        description: "work — solid blue square (--color-primary)",
        attributes: %{id: "story-stage-type-work", name: "Code", type: :work, stage_id: 902, count: 2}
      },
      %Variation{
        id: :type_planning,
        description: "planning — solid violet diamond (--color-secondary)",
        attributes: %{id: "story-stage-type-planning", name: "Plan", type: :planning, stage_id: 903, count: 1}
      },
      %Variation{
        id: :type_review,
        description: "review — hollow amber ring (--color-warning)",
        attributes: %{id: "story-stage-type-review", name: "Review", type: :review, stage_id: 904, count: 1}
      },
      %Variation{
        id: :type_done,
        description: "done — solid green circle (--color-success)",
        attributes: %{id: "story-stage-type-done", name: "Done", type: :done, stage_id: 905, count: 5}
      }
    ]
  end
end
