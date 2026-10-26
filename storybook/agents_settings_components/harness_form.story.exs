defmodule Storybook.AgentsSettingsComponents.HarnessForm do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.AgentsSettingsComponents.harness_form/1
  def render_source, do: :function

  # The Edit / Add harness card (RE433, card mockup 01), with the closed Advanced <details> and
  # the USAGE block and TEST box (RE436).
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

  # RE436 — the USAGE block for each source, from the seed harnesses.
  defp seed(key, id) do
    seed = Enum.find(Hamaca.Agents.seed_harnesses(), &(&1.key == key))
    struct(Schemas.Harness, Map.put(seed, :id, id))
  end

  @allowed ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.42,"resetsAt":1791651000},"seven_day":{"utilization":0.18,"resetsAt":1792000000}}}})

  def variations do
    claude = seed("claude-code", 11)

    [
      %Variation{
        id: :usage_output,
        description: "USAGE from its output, with a TEST result",
        attributes: %{
          form: form(claude),
          harness: claude,
          agent_count: 3,
          usage_test_line: @allowed,
          usage_test: Hamaca.Agents.try_usage_line(claude.usage, @allowed, ~U[2026-10-10 00:00:00Z])
        }
      },
      %Variation{
        id: :usage_command,
        description: "USAGE from a command (Codex)",
        attributes: %{form: form(seed("codex", 12)), harness: seed("codex", 12), agent_count: 1}
      },
      %Variation{
        id: :usage_none,
        description: "USAGE not reported (Gemini CLI)",
        attributes: %{form: form(seed("gemini-cli", 13)), harness: seed("gemini-cli", 13), agent_count: 0}
      },
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
