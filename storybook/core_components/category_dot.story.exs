defmodule Storybook.Components.CoreComponents.CategoryDot do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.CoreComponents.category_dot/1
  def render_source, do: :function

  # One variation per category, straight from the schema, so a new category shows up here too.
  def variations do
    for category <- Schemas.Stage.categories() do
      %Variation{
        id: category,
        description: "The #{category} band's dot (board, Board settings, /docs/how-hamaca-works)",
        attributes: %{category: category}
      }
    end
  end
end
