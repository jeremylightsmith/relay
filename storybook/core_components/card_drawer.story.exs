defmodule Storybook.Components.CoreComponents.CardDrawer do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.card_drawer/1
  def render_source, do: :function

  # The drawer overlays its whole viewport (fixed-position daisyUI
  # drawer-side), so each variation renders inside its own iframe.
  def container, do: {:iframe, style: "height: 720px;"}

  def variations do
    [
      %Variation{
        id: :viewing,
        attributes: %{
          id: "story-drawer-1",
          ref: "RLY-7",
          card: story_card(),
          stage_name: "Code",
          stage_owner: :ai,
          active_owner: :ai,
          current_user_id: 1,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "working", "progress" => 61}, as: :card),
          stages: [%{id: 3, name: "Plan"}, %{id: 4, name: "Code"}, %{id: 7, name: "Done"}],
          conversation: story_conversation(),
          activity: story_activity(),
          comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
        }
      },
      %Variation{
        id: :editing_description,
        attributes: %{
          id: "story-drawer-2",
          ref: "RLY-8",
          card: %{story_card() | description: nil, tag: nil, status: :queued, progress: nil, owners: []},
          stage_name: "Spec",
          stage_owner: :human,
          active_owner: nil,
          current_user_id: 1,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Wire the drawer"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "queued", "progress" => nil}, as: :card),
          editing_description: true,
          description_form: Phoenix.Component.to_form(%{"description" => ""}, as: :card),
          conversation: [],
          activity: [],
          comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
        }
      },
      %Variation{
        id: :needs_input,
        attributes: %{
          id: "story-drawer-3",
          ref: "RLY-9",
          card: %{
            story_card()
            | status: :needs_input,
              progress: nil,
              blocked_since: DateTime.add(DateTime.utc_now(), -3, :hour)
          },
          stage_name: "Code",
          stage_owner: :ai,
          active_owner: :ai,
          current_user_id: 1,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "needs_input", "progress" => nil}, as: :card),
          question: "Should exports use the billing timezone or the viewer's local timezone?",
          answer_form: Phoenix.Component.to_form(%{"body" => ""}, as: :answer),
          conversation: story_conversation(),
          activity: story_activity(),
          comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
        }
      },
      %Variation{
        id: :in_review_gated,
        attributes: %{
          id: "story-drawer-4",
          ref: "RLY-10",
          card: %{story_card() | status: :in_review, progress: nil},
          stage_name: "Review",
          stage_owner: :human,
          active_owner: :ai,
          current_user_id: 2,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "in_review", "progress" => nil}, as: :card),
          review_gate: %{approve_label: "Approve → Deploy", reject_to_name: "Code"},
          reject_form: Phoenix.Component.to_form(%{"note" => ""}, as: :reject),
          conversation: story_conversation(),
          activity: story_activity(),
          comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
        }
      },
      %Variation{
        id: :in_review_request_changes,
        attributes: %{
          id: "story-drawer-5",
          ref: "RLY-11",
          card: %{story_card() | status: :in_review, progress: nil},
          stage_name: "Review",
          stage_owner: :human,
          active_owner: :ai,
          current_user_id: 2,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "in_review", "progress" => nil}, as: :card),
          review_gate: %{approve_label: "Approve → Deploy", reject_to_name: "Code"},
          reject_open: true,
          reject_form: Phoenix.Component.to_form(%{"note" => ""}, as: :reject),
          conversation: story_conversation(),
          activity: story_activity(),
          comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
        }
      },
      %Variation{
        id: :with_branch_and_plan,
        attributes: %{
          id: "story-drawer-6",
          ref: "RLY-12",
          card: %{
            story_card()
            | branch: "rly-12-wire-the-runner",
              plan:
                "## Task 1 — Schema + API\n\n- [x] migration: add branch + plan\n- [x] cast in Card.changeset/2\n- [ ] PATCH /api/cards/:ref accepts both\n\n## Task 2 — Drawer\n\n- [ ] collapsed Plan section\n- [ ] branch chip in the rail",
              pr_url: "https://github.com/acme/relay/pull/42"
          },
          stage_name: "Code",
          stage_owner: :ai,
          active_owner: :ai,
          current_user_id: 1,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "working", "progress" => 61}, as: :card),
          conversation: story_conversation(),
          activity: story_activity(),
          comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
        }
      }
    ]
  end

  defp story_conversation do
    ada = %Schemas.User{id: 1, name: "Ada Lovelace", email: "ada@example.com"}

    [
      {"timeline-comment-1",
       %Schemas.Comment{
         id: 1,
         actor_type: :user,
         user: ada,
         body: "Kicking this off — spec draft attached.",
         inserted_at: ~U[2026-07-02 10:15:00Z]
       }},
      {"timeline-comment-2",
       %Schemas.Comment{
         id: 2,
         actor_type: :agent,
         user: nil,
         body: "Implemented the drawer — ready for review.",
         inserted_at: ~U[2026-07-06 15:30:00Z]
       }}
    ]
  end

  defp story_activity do
    ada = %Schemas.User{id: 1, name: "Ada Lovelace", email: "ada@example.com"}

    [
      {"timeline-activity-2",
       %Schemas.Activity{
         id: 2,
         type: :moved,
         meta: %{"from_stage" => "Spec", "to_stage" => "Code"},
         actor_type: :agent,
         user: nil,
         inserted_at: ~U[2026-07-03 11:00:00Z]
       }},
      {"timeline-activity-1",
       %Schemas.Activity{
         id: 1,
         type: :created,
         meta: %{},
         actor_type: :user,
         user: ada,
         inserted_at: ~U[2026-07-01 09:00:00Z]
       }}
    ]
  end

  defp story_card do
    %{
      title: "Draft the onboarding spec",
      description: "Cover the Google sign-in flow.\n\nList open questions for review.",
      spec: nil,
      tag: "spec",
      status: :working,
      progress: 61,
      blocked_since: nil,
      branch: nil,
      plan: nil,
      pr_url: nil,
      owners: [
        %{id: 1, actor_type: :user, user_id: 1, user: %{name: "Ada Lovelace", email: "ada@example.com"}},
        %{id: 2, actor_type: :agent, user_id: nil, user: nil}
      ],
      inserted_at: ~U[2026-07-01 09:00:00Z],
      updated_at: ~U[2026-07-06 15:30:00Z]
    }
  end
end
