defmodule Storybook.Components.CoreComponents.BoardCard do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.board_card/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :unowned,
        attributes: %{id: "story-card-1", ref: "RLY-1", title: "Wire up Google sign-in"}
      },
      %Variation{
        id: :human_active,
        attributes: %{
          id: "story-card-2",
          ref: "RLY-2",
          title: "Draft the onboarding spec",
          tag: "spec",
          active_owner: :human,
          status: :ready,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}]
        }
      },
      %Variation{
        id: :ai_working,
        attributes: %{
          id: "story-card-3",
          ref: "RLY-3",
          title: "Migrate 40 blog posts",
          active_owner: :ai,
          status: :working,
          progress: 61,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}, %{actor_type: :agent}]
        }
      },
      %Variation{
        id: :ready_parked,
        attributes: %{
          id: "story-card-7",
          ref: "RLY-7",
          title: "Parked, waiting its turn",
          status: :ready,
          stage_type: :queue
        }
      },
      %Variation{
        id: :ready_done_sublane,
        attributes: %{
          id: "story-card-8",
          ref: "RLY-8",
          title: "Finished this stage",
          status: :ready,
          stage_type: :done,
          done: false
        }
      },
      %Variation{
        id: :terminal_done,
        attributes: %{
          id: "story-card-9",
          ref: "RLY-9",
          title: "Ship the landing page",
          status: :ready,
          stage_type: :done,
          done: true,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}]
        }
      },
      %Variation{
        id: :in_review,
        attributes: %{id: "story-card-10", ref: "RLY-10", title: "Ready for your review", status: :in_review}
      },
      %Variation{
        id: :needs_input,
        attributes: %{
          id: "story-card-11",
          ref: "RLY-11",
          title: "Pick the target locale list",
          status: :needs_input,
          question: "Should we ship en-US and de-DE first, or all five at once?",
          active_owner: :ai,
          owners: [%{actor_type: :agent}]
        }
      }
    ]
  end
end
