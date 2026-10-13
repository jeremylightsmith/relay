defmodule Storybook.ExampleBoardComponents.ExampleIntro do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.ExampleBoardComponents.example_intro/1
  def render_source, do: :function

  # RE444: each example board's intro, from its `Relay.Examples` content file.
  def variations do
    for example <- Relay.Examples.all() do
      %Variation{
        id: example.template |> String.replace("-", "_") |> String.to_atom(),
        description: example.name,
        attributes: %{example: example}
      }
    end
  end
end
