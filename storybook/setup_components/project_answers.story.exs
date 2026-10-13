defmodule Storybook.SetupComponents.ProjectAnswers do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.SetupComponents.project_answers/1
  def render_source, do: :function

  # RE446, card mockup "Payoff — first card turns violet, Settings → Setup, connect a machine",
  # frame C: "Project answers", the 5.3 interview answers (`Relay.Setup.project_answers/1`).
  def variations do
    [
      %Variation{
        id: :answered,
        description: "C · the onboarding answers",
        attributes: %{
          id: "setup-project-answers",
          answers: [
            %{id: "done", label: "Done means", answer: "PR merged"},
            %{id: "deploy", label: "Deploy", answer: "fly deploy from main"},
            %{id: "never_touch", label: "Never touch", answer: "priv/repo/migrations"},
            %{id: "capacity", label: "Capacity", answer: "2 runners"}
          ]
        }
      },
      %Variation{
        id: :none,
        description: "No answers yet",
        attributes: %{id: "setup-project-answers", answers: []}
      }
    ]
  end
end
