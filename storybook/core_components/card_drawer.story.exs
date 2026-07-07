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
          stage_name: "Spec",
          stage_owner: :human,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card)
        }
      },
      %Variation{
        id: :editing_description,
        attributes: %{
          id: "story-drawer-2",
          ref: "RLY-8",
          card: %{story_card() | description: nil, tag: nil},
          stage_name: "Code",
          stage_owner: :ai,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Wire the drawer"}, as: :card),
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
      inserted_at: ~U[2026-07-01 09:00:00Z],
      updated_at: ~U[2026-07-06 15:30:00Z]
    }
  end
end
