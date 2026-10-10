defmodule Storybook.AgentsSettingsComponents.HarnessCard do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.AgentsSettingsComponents.harness_card/1
  def render_source, do: :function

  # A harness card (RE433, card mockup 01): COMMAND, MODELS chips, and the red line when an agent
  # on it uses a model the list no longer offers.
  @codex %Schemas.Harness{
    id: 2,
    name: "Codex",
    command: "codex exec --json --model {model} --cd {worktree} [-c model_reasoning_effort={effort}] {prompt}",
    models: ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"]
  }
  @gemini %Schemas.Harness{
    id: 3,
    name: "Gemini CLI",
    command: "gemini -p {prompt} --model {model}",
    models: ["gemini-2.5-flash"]
  }

  def variations do
    [
      %Variation{
        id: :default,
        description: "A harness used by one agent",
        attributes: %{
          harness: @codex,
          agents: [%Schemas.Agent{id: 5, name: "Codex Astra", model: "gpt-6-astra", harness: @codex}]
        }
      },
      %Variation{
        id: :red,
        description: "An agent's model left the list",
        attributes: %{
          harness: @gemini,
          agents: [%Schemas.Agent{id: 4, name: "Gemini Pro", model: "gemini-2.5-pro", harness: @gemini}]
        }
      }
    ]
  end
end
