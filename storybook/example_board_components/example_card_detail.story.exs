defmodule Storybook.ExampleBoardComponents.ExampleCardDetail do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.ExampleBoardComponents.example_card_detail/1
  def render_source, do: :function

  # The modal overlays its whole viewport, so each variation renders in its own iframe.
  def container, do: {:iframe, style: "height: 560px;"}

  # RE444: a sample card opened on an example board — read-only, close is the only button.
  def variations do
    card = %{
      title: "Monthly calendar view",
      ref: "ST11",
      status: :needs_input,
      description: "Show a **month** of streaks at a glance, one dot per day."
    }

    tasks = [%{title: "Calendar grid component", done: true}, %{title: "Week-start setting", done: false}]

    [
      %Variation{
        id: :needs_input,
        description: "Waiting on a question",
        attributes: %{card: card, tasks: tasks, question: "Should the week start on Sunday or Monday?"}
      },
      %Variation{
        id: :in_review,
        description: "No open question",
        attributes: %{card: %{card | status: :in_review}, tasks: tasks, question: nil}
      }
    ]
  end
end
