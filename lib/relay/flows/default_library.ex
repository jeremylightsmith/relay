defmodule Relay.Flows.DefaultLibrary do
  @moduledoc """
  The default flow library as compile-time data — a faithful translation of
  `docs/designs/flows/{spec,plan,code}.jsonc`. Those files stay the authored
  reference: edit them first, then mirror the change here (the README points
  back at this module). Seeded per board, disabled until cutover, by
  `Relay.Flows.seed_default_flows!/1`; triggers are authored as stage
  *names* the seeder resolves to ids.
  """

  @doc ~S|The three default flow definitions ("spec", "plan", "code") as changeset-ready attrs.|
  def all, do: [spec_flow(), plan_flow(), code_flow()]

  # The cheap sync path (RLY-192): fetch, rebase onto origin/main, and — critically — abort a
  # conflicted rebase BEFORE exiting nonzero so the branch is left clean and attached for the
  # next node (RLY-166). Identical in `sync` and `resync`.
  @rebase_onto_main "{relay} git-fetch && { git rebase origin/main || { git rebase --abort; exit 1; }; }"

  # Goal-state prompt for the rebaser agent nodes. Stated as a goal (not just "rebase") because
  # resync_fix is also entered from a failed reverify, where the rebase already completed and the
  # problem is breakage it caused.
  @rebaser_run "Bring this branch onto current origin/main with `mix precommit` green: resolve any rebase conflict preserving both intents, and fix breakage the rebase caused. Escalate with needs-input rather than guessing when the resolution needs human judgement."

  defp spec_flow do
    %{
      key: "spec",
      isolation: :shared_clean,
      trigger: %{pulls_from: "Next up", works_in: "Spec", lands_on: "Spec:Review"},
      nodes: [
        %{key: "brainstorm", type: :agent, run: "/brainstorm {ref}", max_retries: 1}
      ],
      edges: [
        %{from: "start", to: "brainstorm"},
        # needs_input OUTCOME has no edge: the engine parks before consulting any edge
        # (Engine.decide/4 rule 1). The needs_input EDGE below is the other kind of park —
        # an edge target reached when brainstorm reports :failed (RLY-194).
        %{from: "brainstorm", to: "done", on: :succeeded},
        %{from: "brainstorm", to: "needs_input", on: :failed}
      ]
    }
  end

  defp plan_flow do
    %{
      key: "plan",
      isolation: :shared_clean,
      trigger: %{pulls_from: "Spec:Done", works_in: "Plan", lands_on: "Plan:Done"},
      nodes: [
        %{key: "write_plan", type: :agent, run: "/write-plan {ref}", max_retries: 1}
      ],
      edges: [
        %{from: "start", to: "write_plan"},
        %{from: "write_plan", to: "done", on: :succeeded},
        # A hard failure parks for a human rather than ending the run (RLY-194).
        %{from: "write_plan", to: "needs_input", on: :failed}
      ]
    }
  end

  defp code_flow do
    %{
      key: "code",
      isolation: :exclusive,
      trigger: %{pulls_from: "Plan:Done", works_in: "Code", lands_on: "Review"},
      nodes: [
        %{
          key: "branch",
          type: :shell,
          run:
            "{relay} git-fetch && git checkout -B {branch} origin/main && " <>
              ~s({relay} card {ref} --json | jq -r '.plan // empty' > "$RELAY_PLAN" && test -s "$RELAY_PLAN")
        },
        %{
          key: "implement",
          type: :agent,
          model: "sonnet",
          effort: "high",
          max_retries: 1,
          expects_commits: true,
          foreach: "card.sub_tasks",
          agent: "plan-implementer",
          run:
            "Implement the task named {sub_task} from the card's plan with strict red/green TDD. " <>
              "One task only — do not start the next one. If reviewer findings are attached, address them."
        },
        %{
          key: "spec_review",
          type: :agent,
          model: "sonnet",
          agent: "spec-reviewer",
          run: "Review the just-implemented task against its spec in the plan: nothing missing, nothing extra."
        },
        %{
          key: "quality_review",
          type: :agent,
          model: "opus",
          agent: "quality-reviewer",
          run: "Judge whether the change is well-built: clean, conventional, meaningfully tested."
        },
        %{key: "sync", type: :shell, run: @rebase_onto_main},
        %{key: "sync_fix", type: :agent, model: "sonnet", agent: "rebaser", run: @rebaser_run},
        %{key: "precommit", type: :gate, run: "mix precommit"},
        %{
          key: "final_review",
          type: :agent,
          model: "opus",
          agent: "final-reviewer",
          run:
            "Whole-branch cross-cutting review — issues only visible across the whole diff. " <>
              "Includes the docs/architecture freshness check."
        },
        %{
          key: "final_fix",
          type: :agent,
          model: "opus",
          agent: "final-fixer",
          expects_commits: true,
          run: "Fix every blocking finding from the review in one consolidated pass; keep the suite green."
        },
        %{
          key: "smoke",
          type: :agent,
          model: "opus",
          agent: "smoke-tester",
          run:
            "Drive the new behavior end-to-end through the running app; screenshot each " <>
              "new/changed state against its docs/designs artboard."
        },
        %{
          key: "smoke_fix",
          type: :agent,
          model: "opus",
          expects_commits: true,
          run: "Fix what the smoke run proved broken; keep the suite green."
        },
        %{
          key: "acceptance",
          type: :agent,
          model: "opus",
          agent: "acceptance-tester",
          run:
            "Run the card's acceptance criteria verbatim; return a per-criterion verdict " <>
              "(human-verify criteria don't block)."
        },
        %{
          key: "acceptance_fix",
          type: :agent,
          model: "opus",
          expects_commits: true,
          run: "Fix the failing acceptance criteria; keep the suite green."
        },
        %{
          key: "post",
          type: :agent,
          model: "sonnet",
          run: "Post the acceptance checklist and smoke screenshots to card {ref} as one comment."
        },
        %{key: "resync", type: :shell, run: @rebase_onto_main},
        %{key: "resync_fix", type: :agent, model: "sonnet", agent: "rebaser", run: @rebaser_run},
        %{key: "reverify", type: :gate, run: "mix precommit"},
        %{
          key: "merge",
          type: :shell,
          run:
            "state=$(gh pr view {branch} --json state -q .state 2>/dev/null || echo \"\"); " <>
              "[ \"$state\" = MERGED ] && exit 0; " <>
              "git push --force-with-lease origin HEAD:refs/heads/{branch} && " <>
              "url=$(gh pr view {branch} --json url -q .url 2>/dev/null || " <>
              "gh pr create --fill --head {branch} --base main) && " <>
              "{relay} pr {ref} \"$url\" && gh pr merge {branch} --squash"
        }
      ],
      edges: [
        %{from: "start", to: "branch"},
        %{from: "branch", to: "implement", on: :succeeded},
        %{from: "implement", to: "spec_review", on: :succeeded},
        %{from: "spec_review", to: "implement", on: :failed, max_loops: 3},
        %{from: "spec_review", to: "quality_review", on: :succeeded},
        %{from: "quality_review", to: "implement", on: :failed, max_loops: 3},
        %{from: "quality_review", to: "implement", on: :succeeded, when: :foreach_remaining},
        %{from: "quality_review", to: "sync", on: :succeeded, when: :foreach_exhausted},
        %{from: "sync", to: "precommit", on: :succeeded},
        %{from: "sync", to: "sync_fix", on: :failed},
        %{from: "sync_fix", to: "precommit", on: :succeeded},
        %{from: "precommit", to: "final_fix", on: :failed, max_loops: 2},
        %{from: "precommit", to: "final_review", on: :succeeded},
        %{from: "final_review", to: "final_fix", on: :failed, max_loops: 2},
        %{from: "final_review", to: "smoke", on: :succeeded},
        %{from: "final_fix", to: "precommit", on: :succeeded},
        %{from: "smoke", to: "smoke_fix", on: :failed, max_loops: 2},
        %{from: "smoke_fix", to: "smoke", on: :succeeded},
        %{from: "smoke", to: "acceptance", on: :succeeded},
        %{from: "acceptance", to: "acceptance_fix", on: :failed, max_loops: 2},
        %{from: "acceptance_fix", to: "acceptance", on: :succeeded},
        %{from: "acceptance", to: "post", on: :succeeded},
        %{from: "post", to: "resync", on: :succeeded},
        %{from: "resync", to: "reverify", on: :succeeded},
        %{from: "resync", to: "resync_fix", on: :failed},
        %{from: "resync_fix", to: "reverify", on: :succeeded},
        %{from: "reverify", to: "resync_fix", on: :failed, max_loops: 2},
        %{from: "reverify", to: "merge", on: :succeeded},
        %{from: "merge", to: "done", on: :succeeded},
        %{from: "merge", to: "resync", on: :failed, max_loops: 2},
        # RLY-194: every agent node parks on a hard :failed instead of dead-ending. implement
        # carries max_retries: 1, so it retries once THEN parks; the fixers, post and the RLY-192
        # rebasers park on their first hard failure (a fixer already sits under a max_loops fix
        # cycle; a rebaser already escalates judgement calls via needs-input). RLY-224 adds branch
        # (a :shell node): a fetch race that survives git_fetch_with_retry's bounded retries (or
        # any other branch failure, e.g. empty plan.md) parks too. merge/sync/resync stay
        # unrouted :shell.
        %{from: "implement", to: "needs_input", on: :failed},
        %{from: "sync_fix", to: "needs_input", on: :failed},
        %{from: "final_fix", to: "needs_input", on: :failed},
        %{from: "smoke_fix", to: "needs_input", on: :failed},
        %{from: "acceptance_fix", to: "needs_input", on: :failed},
        %{from: "resync_fix", to: "needs_input", on: :failed},
        %{from: "post", to: "needs_input", on: :failed},
        %{from: "branch", to: "needs_input", on: :failed}
      ]
    }
  end
end
