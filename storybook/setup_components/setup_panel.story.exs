defmodule Storybook.SetupComponents.SetupPanel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Schemas.BoardSetupStep

  def function, do: &RelayWeb.SetupComponents.setup_panel/1
  def render_source, do: :function

  # The panel's controls use the page-wide `setup-` ids, so each variation gets its own iframe.
  def container, do: {:iframe, style: "height: 980px;"}

  # RE446 adds the payoff variation and D (connect a machine), card mockup "Payoff — first card turns violet, Settings →
  # Setup, connect a machine", frame A's panel.
  # RE443, card mockup "Wizard — docked left on the empty board, every step state + expert
  # toggle": frames A (key step active), B (LLM pick with the Three-brain warning) and C (install
  # failed in preflight), D (the onboard loop running, RE445), plus the expert toggle on.
  # Fixture checklists come from `Relay.Setup.preview_checklist/2`, the same builder
  # `Relay.Setup.checklist/1` uses, with no database.
  def variations do
    [_pending, active, waiting, done, failed, _skipped] = BoardSetupStep.statuses()
    install = "curl -fsSL https://relayboard.fly.dev/b/streaks/install | sh"

    [
      %Variation{
        id: :a_key_step,
        description: "A · key step active, the key shown once with \"I've saved it — next\"",
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
        id: :d_onboard_loop_running,
        description: "D · onboard loop running, 5.6 waiting on your PR",
        attributes: %{
          id: "setup-panel",
          board_name: "Streaks",
          board_slug: "streaks",
          now: ~U[2026-10-12 14:40:00Z],
          checklist:
            checklist(%{
              "1" => done,
              "2" => done,
              "3" => done,
              "4" => done,
              "5" => %{status: active, reached_at: ~U[2026-10-12 14:28:00Z]},
              "5.1" => %{status: done, evidence: "2 flows"},
              "5.2" => %{status: done, evidence: "elixir · mix precommit"},
              "5.3" => %{status: done, evidence: "9 of 9 answered"},
              "5.4" => %{status: done, evidence: "dropped screenshots"},
              "5.5" => %{status: done, evidence: "enabled"},
              "5.6" => %{
                status: waiting,
                evidence: "PR #12 open · checked 14:31",
                data: %{"pr_url" => "https://github.com/jl/streaks/pull/12", "base" => "main"}
              }
            })
        }
      },
      %Variation{
        id: :payoff,
        description: "Payoff · the first card claimed: You're set up, 7 of 7 (RE446)",
        attributes: %{
          id: "setup-panel",
          board_name: "Streaks",
          board_slug: "streaks",
          hide_explanations: true,
          checklist: payoff_checklist()
        }
      },
      %Variation{
        id: :d_connect_a_machine,
        description: "D · connect a machine: Sam's member note, the board-wide steps skipped, 2 of 6 (RE446)",
        attributes: %{
          id: "setup-panel",
          board_name: "Streaks",
          board_slug: "streaks",
          user_name: "Sam",
          checklist: connect_checklist()
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

  # Every step done, setup taking 40 minutes from the board's creation to the first claim.
  defp payoff_checklist do
    [_pending, _active, _waiting, done, _failed, _skipped] = BoardSetupStep.statuses()
    runner = Relay.Setup.step_id(:runner)
    claim = Relay.Setup.step_id(:first_claim)
    [created | _] = Relay.Setup.steps()

    Relay.Setup.steps()
    |> Map.new(&{&1.id, done})
    |> Map.merge(%{
      created.id => %{status: done, completed_at: ~U[2026-10-12 14:02:00Z], evidence: "6 stages · 2 flows · 14:02"},
      runner => %{status: done, evidence: "heartbeat 14:40 · jl-mbp · claude logged_in"},
      claim => %{
        status: done,
        completed_at: ~U[2026-10-12 14:42:00Z],
        evidence: "STR1 claimed 14:42 by jl-mbp",
        data: %{"card_ref" => "STR1", "card_id" => 1, "runner" => "jl-mbp", "machine" => "jl-mbp", "verb" => "planning"}
      }
    })
    |> checklist()
  end

  # An unsaved connect (RE446, frame D): `Relay.Setup.connect_skips/0` skipped, step 3 active and
  # the board's first claim read into step 7's board-wide evidence.
  defp connect_checklist do
    [_pending, active, _waiting, done, _failed, skipped] = BoardSetupStep.statuses()
    [created | _] = Relay.Setup.steps()
    evidence = %{created.id => "already set up", Relay.Setup.step_id(:llm) => "board-wide · already chosen"}

    rows =
      Relay.Setup.connect_skips()
      |> Map.new(&{&1, %{status: skipped, evidence: evidence[&1]}})
      |> Map.put(Relay.Setup.step_id(:key), active)

    Relay.Setup.preview_checklist(rows, %{
      template: "Bare minimum",
      llm: Relay.Setup.onboarding_llm("claude-code"),
      connect?: true,
      board_name: "Streaks",
      board_claim: %{status: done, completed_at: ~U[2026-10-12 14:42:00Z], data: %{"card_ref" => "STR1"}}
    })
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
