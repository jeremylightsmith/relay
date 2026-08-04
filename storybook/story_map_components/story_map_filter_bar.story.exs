defmodule Storybook.StoryMapComponents.StoryMapFilterBar do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.StoryMapComponents.story_map_filter_bar/1
  def render_source, do: :function

  defp dana(selected?) do
    %{
      key: "u:3",
      actor: :human,
      name: "Dana Kim",
      email: "dana.kim@acme.co",
      avatar_url: nil,
      selected?: selected?
    }
  end

  defp mara(selected?) do
    %{
      key: "u:4",
      actor: :human,
      name: "Mara Lopez",
      email: "mara@acme.co",
      avatar_url: nil,
      selected?: selected?
    }
  end

  defp ai(selected?) do
    %{key: "agent", actor: :ai, name: "Relay AI", email: nil, avatar_url: nil, selected?: selected?}
  end

  def variations do
    [
      %Variation{
        id: :resting,
        description: "No filter: no Clear link, and the count reads the plain total.",
        attributes: %{
          chips: [dana(false), mara(false), ai(false)],
          needs_input: false,
          focus_name: nil,
          filter_active: false,
          visible: 24,
          total: 24
        }
      },
      %Variation{
        id: :owner_selected,
        description: "One owner chip on: it takes that person's identity hue, and Clear appears.",
        attributes: %{
          chips: [dana(true), mara(false), ai(false)],
          needs_input: false,
          focus_name: nil,
          filter_active: true,
          visible: 7,
          total: 24
        }
      },
      %Variation{
        id: :needs_input,
        description: "The Needs-input toggle on, in the artboard's amber.",
        attributes: %{
          chips: [dana(false), mara(false), ai(false)],
          needs_input: true,
          focus_name: nil,
          filter_active: true,
          visible: 3,
          total: 24
        }
      },
      %Variation{
        id: :focusing,
        description: "Focus mode: the violet ◎ chip is how you get out.",
        attributes: %{
          chips: [dana(false), mara(false), ai(true)],
          needs_input: false,
          focus_name: "Checkout",
          filter_active: true,
          visible: 9,
          total: 24
        }
      }
    ]
  end
end
