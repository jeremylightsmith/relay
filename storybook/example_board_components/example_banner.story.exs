defmodule Storybook.ExampleBoardComponents.ExampleBanner do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.ExampleBoardComponents.example_banner/1
  def render_source, do: :function

  # RE444: one banner per template, from `Hamaca.Boards.templates/0`.
  def variations do
    for template <- Hamaca.Boards.templates() do
      %Variation{
        id: template.slug |> String.replace("-", "_") |> String.to_atom(),
        description: "#{template.name} example",
        attributes: %{
          template_name: template.name,
          slug: template.slug,
          use_href: "/boards?template=#{template.slug}"
        }
      }
    end
  end
end
