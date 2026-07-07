defmodule Storybook.Components.CoreComponents.StatusBadge do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.status_badge/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :queued, attributes: %{status: :queued}},
      %Variation{id: :working, attributes: %{status: :working}},
      %Variation{id: :working_with_progress, attributes: %{status: :working, progress: 61}},
      %Variation{id: :needs_input, attributes: %{status: :needs_input}},
      %Variation{id: :in_review, attributes: %{status: :in_review}},
      %Variation{id: :done, attributes: %{status: :done}}
    ]
  end
end
