defmodule Storybook.Components.CoreComponents.SupportersRow do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.supporters_row/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :few,
        attributes: %{
          total: 2,
          supporters: [%{name: "Maya L.", email: "maya@example.com"}, %{name: "Dana K.", email: "dana@example.com"}]
        }
      },
      %Variation{
        id: :with_more,
        attributes: %{
          total: 96,
          supporters: [
            %{name: "Maya L.", email: "maya@example.com"},
            %{name: "Dana K.", email: "dana@example.com"},
            %{name: "Sam Y.", email: "sam@example.com"}
          ]
        }
      }
    ]
  end
end
