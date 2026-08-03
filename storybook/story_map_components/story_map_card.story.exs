defmodule Storybook.StoryMapComponents.StoryMapCard do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.StoryMapComponents.story_map_card/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :plain,
        attributes: %{
          id: "story-map-card-1",
          ref: "RLY-100",
          title: "Add SSO for enterprise accounts",
          badge: "BACKLOG",
          hue: :neutral
        }
      },
      %Variation{
        id: :working_with_percentage,
        attributes: %{
          id: "story-map-card-2",
          ref: "RLY-106",
          title: "Migrate 40 blog posts to the new CMS",
          badge: "CODE · 62%",
          hue: :violet,
          pct: 62,
          active_owner: :ai,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}, %{actor_type: :agent}]
        }
      },
      %Variation{
        id: :needs_you,
        attributes: %{
          id: "story-map-card-3",
          ref: "RLY-107",
          title: "Rewrite the onboarding tooltips",
          badge: "NEEDS YOU",
          hue: :amber,
          avatar: :bang
        }
      },
      %Variation{
        id: :stalled,
        attributes: %{
          id: "story-map-card-4",
          ref: "RLY-108",
          title: "Generate the API client from OpenAPI",
          badge: "STALLED",
          hue: :amber,
          active_owner: :ai,
          owners: [%{actor_type: :agent}]
        }
      },
      %Variation{
        id: :done,
        attributes: %{
          id: "story-map-card-5",
          ref: "RLY-110",
          title: "Add keyboard shortcuts",
          badge: "DONE",
          hue: :green,
          done: true,
          avatar: :check
        }
      },
      %Variation{
        id: :map_zoom,
        attributes: %{
          id: "story-map-card-6",
          ref: "RLY-111",
          title: "Add SSO for enterprise accounts",
          badge: "CODE",
          hue: :violet,
          zoom: :map
        }
      },
      %Variation{
        id: :compact_zoom,
        attributes: %{
          id: "story-map-card-7",
          ref: "RLY-112",
          title: "Add SSO for enterprise accounts",
          badge: "CODE",
          hue: :violet,
          zoom: :compact
        }
      },
      %Variation{
        id: :full_zoom,
        attributes: %{
          id: "story-map-card-8",
          ref: "RLY-113",
          title: "Add SSO for enterprise accounts",
          badge: "CODE · 62%",
          hue: :violet,
          pct: 62,
          zoom: :full,
          active_owner: :ai,
          owners: [%{actor_type: :agent}]
        }
      }
    ]
  end
end
