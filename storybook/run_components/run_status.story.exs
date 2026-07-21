defmodule Storybook.RunComponents.RunStatus do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunStatus.descriptor_row/1
  def render_source, do: :function

  def variations do
    for status <- Ecto.Enum.values(Schemas.Run, :status) do
      %Variation{id: status, attributes: %{status: status}}
    end
  end
end
