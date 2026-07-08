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
          stage_owner: :human,
          status: :queued,
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
          stage_owner: :ai,
          status: :working,
          progress: 61,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}, %{actor_type: :agent}]
        }
      },
      %Variation{
        id: :needs_input,
        attributes: %{
          id: "story-card-4",
          ref: "RLY-4",
          title: "Pick the target locale list",
          active_owner: :ai,
          stage_owner: :ai,
          status: :needs_input,
          owners: [%{actor_type: :agent}]
        }
      },
      %Variation{
        id: :mismatch_meant_for_agents,
        attributes: %{
          id: "story-card-5",
          ref: "RLY-5",
          title: "Human card parked in Code",
          active_owner: :human,
          stage_owner: :ai,
          status: :queued
        }
      },
      %Variation{
        id: :mismatch_meant_for_humans,
        attributes: %{
          id: "story-card-6",
          ref: "RLY-6",
          title: "AI card parked in Review",
          active_owner: :ai,
          stage_owner: :human,
          status: :working,
          progress: 20
        }
      },
      %Variation{
        id: :done,
        attributes: %{
          id: "story-card-7",
          ref: "RLY-7",
          title: "Ship the landing page",
          active_owner: :human,
          stage_owner: :human,
          status: :done,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}]
        }
      }
    ]
  end
end
