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
          stages: [%{id: 3, name: "Plan"}, %{id: 4, name: "Code"}, %{id: 7, name: "Done"}]
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
          description_form: Phoenix.Component.to_form(%{"description" => ""}, as: :card)
        }
      }
    ]
  end

  defp story_card do
    %{
      title: "Draft the onboarding spec",
      description: "Cover the Google sign-in flow.\n\nList open questions for review.",
      tag: "spec",
      status: :working,
      progress: 61,
      owners: [
        %{id: 1, actor_type: :user, user_id: 1, user: %{name: "Ada Lovelace", email: "ada@example.com"}},
        %{id: 2, actor_type: :agent, user_id: nil, user: nil}
      ],
      inserted_at: ~U[2026-07-01 09:00:00Z],
      updated_at: ~U[2026-07-06 15:30:00Z]
    }
  end
end
