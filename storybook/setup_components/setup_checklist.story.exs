defmodule Storybook.SetupComponents.SetupChecklist do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Schemas.BoardSetupStep

  def function, do: &RelayWeb.SetupComponents.setup_checklist/1
  def render_source, do: :function

  # RE443, card mockups "Wizard — docked left on the empty board, every step state + expert
  # toggle" and "Mobile — read-only checklist, continue on a computer". Fixture checklists come
  # from `Relay.Setup.preview_checklist/2`, the same builder `Relay.Setup.checklist/1` uses, with
  # no database.
  def variations do
    [pending, active, waiting, done, failed, skipped] = BoardSetupStep.statuses()

    [
      %Variation{
        id: :pick_llm,
        description: "Step 2 active: the LLM picker (Gemini CLI disabled, coming soon)",
        attributes: %{id: "setup-story-pick", checklist: checklist(%{"1" => done, "2" => active})}
      },
      %Variation{
        id: :key_shown,
        description: "Step 3 active, the shown-once key on screen",
        attributes: %{
          id: "setup-story-key",
          checklist: checklist(%{"1" => done, "2" => done, "3" => active}),
          token: "relay_9f3a2b1c4d5e_0123456789abcdef0123456789abcdef"
        }
      },
      %Variation{
        id: :key_reload,
        description: "Step 3 active after a reload: the key is gone, mint a new one",
        attributes: %{id: "setup-story-mint", checklist: checklist(%{"1" => done, "2" => done, "3" => active})}
      },
      %Variation{
        id: :install_failed,
        description: "Step 4 failed in preflight: the fix, the install command and the checks",
        attributes: %{
          id: "setup-story-failed",
          checklist:
            checklist(%{"1" => done, "2" => done, "3" => done, "4" => Map.put(install_failure(), :status, failed)}),
          install_command: "curl -fsSL https://relayboard.fly.dev/b/streaks/install | sh",
          board_slug: "streaks"
        }
      },
      %Variation{
        id: :every_state,
        description: "One step in each state: done, active, waiting, failed, pending, skipped",
        attributes: %{
          id: "setup-story-states",
          checklist:
            checklist(%{
              "1" => done,
              "2" => active,
              "3" => %{status: waiting, evidence: "preflight passed 14:10 · jl-mbp"},
              "4" => %{status: failed, evidence: "preflight failed 14:07 · claude not found"},
              "5" => pending,
              "6" => skipped
            })
        }
      },
      %Variation{
        id: :read_only,
        description: "Read-only (phones): no picker, key or install command; step 3 needs a computer",
        attributes: %{id: "setup-story-read-only", checklist: checklist(%{"1" => done, "2" => active}), mode: :read_only}
      },
      %Variation{
        id: :hide_explanations,
        description: "\"I know Relay, hide explanations\": no why lines, no What this does",
        attributes: %{
          id: "setup-story-expert",
          checklist: checklist(%{"1" => done, "2" => active}),
          hide_explanations: true
        }
      }
    ]
  end

  defp install_failure do
    %{
      evidence: "preflight failed 14:07 · claude not found · jl-mbp",
      error: "Preflight stopped: Claude Code isn't on your PATH",
      data: %{
        "headline" => "Preflight stopped: Claude Code isn't on your PATH",
        "fix" => "Install it, open a new terminal, and run the same command again. Nothing was written.",
        "fix_command" => "npm install -g @anthropic-ai/claude-code",
        "checks" => [
          %{"id" => "git_repo", "label" => "git repo", "ok" => true, "detail" => "~/src/streaks"},
          %{"id" => "remote", "label" => "remote", "ok" => true, "detail" => "origin → github.com/jl/streaks"},
          %{"id" => "default_branch", "label" => "default branch", "ok" => true, "detail" => "main"},
          %{"id" => "cli", "label" => "claude on PATH", "ok" => false, "detail" => "not found"}
        ]
      }
    }
  end

  # `Relay.Setup.preview_checklist/2`: `states` maps a step id to a status, or to a row-shaped
  # map; every other step is pending.
  defp checklist(states) do
    Relay.Setup.preview_checklist(states, %{template: "Bare minimum", llm: Relay.Setup.onboarding_llm("claude-code")})
  end
end
