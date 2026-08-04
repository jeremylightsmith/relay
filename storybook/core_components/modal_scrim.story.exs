defmodule Storybook.Components.CoreComponents.ModalScrim do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.modal_scrim/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :default, attributes: %{class: "!absolute"}},
      %Variation{id: :below_a_drawer, attributes: %{class: "!absolute", "phx-click": "close"}}
    ]
  end
end
