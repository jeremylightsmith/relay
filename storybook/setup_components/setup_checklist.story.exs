defmodule Storybook.SetupComponents.SetupChecklist do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Schemas.BoardSetupStep

  def function, do: &RelayWeb.SetupComponents.setup_checklist/1
  def render_source, do: :function

  # RE443, card mockups "Wizard — docked left on the empty board, every step state + expert
  # toggle" and "Mobile — read-only checklist, continue on a computer"; RE445 adds step 5's frames
  # D, F1, F2 and E. Fixture checklists come
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
        id: :d_onboard_pr_wait,
        description: "D · onboard loop running: 5.1–5.5 done, 5.6 waiting on your PR",
        attributes: %{id: "setup-story-onboard-pr", checklist: checklist(onboard_pr_wait()), now: onboard_now()}
      },
      %Variation{
        id: :f1_interview,
        description: "F1 · 5.3 interview: answers appear as you give them",
        attributes: %{id: "setup-story-interview", checklist: checklist(interview()), now: onboard_now()}
      },
      %Variation{
        id: :f2_customize,
        description: "F2 · 5.4 customize: propose, agree one at a time, then apply",
        attributes: %{id: "setup-story-customize", checklist: checklist(customize()), now: onboard_now()}
      },
      %Variation{
        id: :e_substep_failed,
        description: "E · a loop step failed three times, explanations hidden",
        attributes: %{
          id: "setup-story-substep-failed",
          checklist: checklist(substep_failed()),
          now: onboard_now(),
          hide_explanations: true
        }
      },
      %Variation{
        id: :onboard_read_only,
        description: "Read-only (phones): step 5's sub-step list only, no blocks",
        attributes: %{id: "setup-story-onboard-read-only", checklist: checklist(onboard_pr_wait()), mode: :read_only}
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

  # Step 5's frames (RE445): steps 1–4 done, step 5 reached `minutes` before `onboard_now/0`.
  defp onboard_now, do: ~U[2026-10-12 14:40:00Z]

  defp onboard(minutes, subs) do
    ~w(1 2 3 4)
    |> Map.new(&{&1, :done})
    |> Map.put("5", %{status: :active, reached_at: DateTime.add(onboard_now(), -minutes * 60)})
    |> Map.merge(subs)
  end

  defp onboard_pr_wait do
    onboard(12, %{
      "5.1" => %{status: :done, evidence: "2 flows"},
      "5.2" => %{status: :done, evidence: "elixir · mix precommit"},
      "5.3" => %{status: :done, evidence: "9 of 9 answered"},
      "5.4" => %{status: :done, evidence: "dropped screenshots"},
      "5.5" => %{status: :done, evidence: "enabled"},
      "5.6" => %{
        status: :waiting,
        evidence: "PR #12 open · checked 14:31",
        data: %{"pr_url" => "https://github.com/jl/streaks/pull/12", "base" => "main"}
      }
    })
  end

  defp interview do
    onboard(5, %{
      "5.1" => %{status: :done, evidence: "2 flows"},
      "5.2" => %{status: :done, evidence: "elixir"},
      "5.3" => %{status: :waiting, evidence: "4 of 9", data: %{"answers" => four_answers()}}
    })
  end

  defp customize do
    answers =
      Map.merge(four_answers(), %{
        "ui" => "mix phx.server · :4000",
        "never_touch" => "priv/repo/migrations, config/prod.exs",
        "warm_up" => "_build, deps",
        "capacity" => "2 cards · ≤ 60% of plan",
        "misfits" => "none"
      })

    onboard(9, %{
      "5.1" => %{status: :done, evidence: "2 flows"},
      "5.2" => %{status: :done, evidence: "elixir"},
      "5.3" => %{status: :done, evidence: "9 of 9 answered", data: %{"answers" => answers}},
      "5.4" => %{status: :waiting, evidence: "3 of 5 agreed", data: %{"changes" => changes()}}
    })
  end

  defp substep_failed do
    onboard(31, %{
      "5.1" => %{status: :done, evidence: "2 flows"},
      "5.2" => %{status: :done, evidence: "elixir"},
      "5.3" => %{status: :done, evidence: "9/9"},
      "5.4" => %{status: :done, evidence: "3 changes applied"},
      "5.5" => %{
        status: :failed,
        error: "422 flow “implement”: node validate has no command",
        evidence: "422 · attempt 3/3",
        data: %{"attempts" => 3}
      }
    })
  end

  defp four_answers do
    %{
      "done" => "PR merged",
      "landing" => "PR into main",
      "deploy" => "stays human",
      "baton" => "plans + finished code"
    }
  end

  defp changes do
    [
      %{"summary" => "validate: `mix test` → `mix precommit`", "decision" => "accepted"},
      %{"summary" => "drop `screenshots` node from implement", "decision" => "rejected"},
      %{"summary" => "runner.json: capacity 3 → 2", "decision" => "edited", "note" => "→ 2, limit 60%"},
      %{"summary" => "warm-up hook: copy `_build`, `deps`", "decision" => "asking"},
      %{"summary" => "never-touch list → every flow prompt", "decision" => "pending"}
    ]
  end

  # `Relay.Setup.preview_checklist/2`: `states` maps a step id to a status, or to a row-shaped
  # map; every other step is pending.
  defp checklist(states) do
    Relay.Setup.preview_checklist(states, %{template: "Bare minimum", llm: Relay.Setup.onboarding_llm("claude-code")})
  end
end
