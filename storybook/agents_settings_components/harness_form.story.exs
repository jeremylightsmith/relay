defmodule Storybook.AgentsSettingsComponents.HarnessForm do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.AgentsSettingsComponents.harness_form/1
  def render_source, do: :function

  # The Edit / Add harness card (RE433, card mockup 01), with the closed Advanced <details>.
  @claude %Schemas.Harness{
    id: 1,
    name: "Claude Code",
    command: "claude -p {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json",
    models: ["opus", "sonnet", "haiku"],
    resume_command: "claude -p --resume {session} {prompt} --model {model}",
    session_id_path: ".session_id",
    signed_in_check: "claude auth status"
  }

  defp form(harness), do: harness |> Schemas.Harness.changeset(%{}) |> Phoenix.Component.to_form()

  def variations do
    [
      %Variation{
        id: :edit,
        description: "Editing Claude Code",
        attributes: %{form: form(@claude), harness: @claude, agent_count: 3}
      },
      %Variation{
        id: :add,
        description: "+ Add harness",
        attributes: %{form: form(%Schemas.Harness{}), harness: nil}
      },
      %Variation{
        id: :refused_remove,
        description: "Remove refused — agents still use it",
        attributes: %{
          form: form(@claude),
          harness: @claude,
          agent_count: 3,
          error: "Claude Code is used by Claude Haiku, Claude Opus, Claude Sonnet. Delete or move those agents first."
        }
      }
    ]
  end
end
