defmodule Storybook.SetupComponents.SetupPanel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Schemas.BoardSetupStep

  def function, do: &RelayWeb.SetupComponents.setup_panel/1
  def render_source, do: :function

  # The panel's controls use the page-wide `setup-` ids, so each variation gets its own iframe.
  def container, do: {:iframe, style: "height: 980px;"}

  # RE443, card mockup "Wizard — docked left on the empty board, every step state + expert
  # toggle": frames A (key step active), B (LLM pick with the Three-brain warning) and C (install
  # failed in preflight), plus the expert toggle on. Fixture checklists come from
  # `Relay.Setup.preview_checklist/2`, the same builder `Relay.Setup.checklist/1` uses, with no
  # database.
  def variations do
    [_pending, active, _waiting, done, failed, _skipped] = BoardSetupStep.statuses()
    install = "curl -fsSL https://relayboard.fly.dev/b/streaks/install | sh"

    [
      %Variation{
        id: :a_key_step,
        description: "A · key step active, the key shown once",
        attributes: %{
          id: "setup-panel",
          board_name: "Streaks",
          checklist: checklist(%{"1" => done, "2" => done, "3" => active}),
          token: "relay_9f3a2b1c4d5e_0123456789abcdef0123456789abcdef"
        }
      },
      %Variation{
        id: :b_pick_llm_three_brain,
        description: "B · pick the LLM on a Three-brain board (the warning box)",
        attributes: %{
          id: "setup-panel",
          board_name: "Streaks",
          checklist:
            checklist(%{"1" => done, "2" => active},
              template: "Three-brain",
              warning: "Needs runners signed in to Claude Code, Codex and Gemini CLI"
            )
        }
      },
      %Variation{
        id: :c_install_failed,
        description: "C · install failed in preflight",
        attributes: %{
          id: "setup-panel",
          board_name: "Streaks",
          board_slug: "streaks",
          install_command: install,
          checklist:
            checklist(%{"1" => done, "2" => done, "3" => done, "4" => Map.put(install_failure(), :status, failed)})
        }
      },
      %Variation{
        id: :hide_explanations,
        description: "I know Relay: no diagram, why lines or What this does",
        attributes: %{
          id: "setup-panel",
          board_name: "Streaks",
          board_slug: "streaks",
          install_command: install,
          hide_explanations: true,
          checklist: checklist(%{"1" => done, "2" => done, "3" => done, "4" => active})
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
  defp checklist(states, opts \\ []) do
    Relay.Setup.preview_checklist(states, %{
      template: Keyword.get(opts, :template, "Bare minimum"),
      template_warning: Keyword.get(opts, :warning),
      llm: Relay.Setup.onboarding_llm("claude-code")
    })
  end
end
