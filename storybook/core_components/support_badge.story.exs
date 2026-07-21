defmodule Storybook.Components.CoreComponents.SupportBadge do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.support_badge/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :pill_not_voted, attributes: %{count: 12, voted: false, variant: :pill}},
      %Variation{id: :pill_voted, attributes: %{count: 13, voted: true, variant: :pill}},
      %Variation{id: :pill_large, attributes: %{count: 156, voted: true, variant: :pill, size: :lg}},
      %Variation{id: :count, attributes: %{count: 7, variant: :count}}
    ]
  end
end
