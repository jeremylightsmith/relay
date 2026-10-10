defmodule Storybook.AgentsSettingsComponents.AgentForm do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.AgentsSettingsComponents.agent_form/1
  def render_source, do: :function

  # The Add / Edit agent panel (RE433, card mockup 01). Forms are built from the schema changeset
  # directly so the story needs no database.
  @claude %Schemas.Harness{id: 1, name: "Claude Code", models: ["opus", "sonnet", "haiku"]}
  @codex %Schemas.Harness{id: 2, name: "Codex", models: ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"]}
  @gemini %Schemas.Harness{id: 3, name: "Gemini CLI", models: ["gemini-2.5-flash"]}

  defp form(agent, harness, attrs \\ %{}),
    do: agent |> Schemas.Agent.changeset(attrs, harness) |> Phoenix.Component.to_form()

  def variations do
    red = %Schemas.Agent{id: 4, name: "Gemini Pro", model: "gemini-2.5-pro", harness_id: 3, harness: @gemini}
    opus = %Schemas.Agent{id: 1, name: "Claude Opus", model: "opus", harness_id: 1, harness: @claude}

    [
      %Variation{
        id: :add,
        description: "Add agent — Codex picked, its models only",
        attributes: %{
          panel: {:new, @codex},
          harnesses: [@claude, @codex, @gemini],
          form: form(%Schemas.Agent{}, @codex, %{"harness_id" => 2, "model" => "gpt-6-astra", "name" => "Codex Astra"})
        }
      },
      %Variation{
        id: :edit,
        description: "Edit a healthy agent — model preselected, Save enabled",
        attributes: %{panel: {:edit, opus}, form: form(opus, @claude)}
      },
      %Variation{
        id: :edit_red,
        description: "Edit a red agent — Choose a model…, Save disabled",
        attributes: %{panel: {:edit, red}, form: form(red, @gemini)}
      },
      %Variation{
        id: :refused_delete,
        description: "Delete refused — the board default",
        attributes: %{
          panel: {:edit, opus},
          form: form(opus, @claude),
          error: "Claude Opus is the board default. Make another agent the default first."
        }
      }
    ]
  end
end
