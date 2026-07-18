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
        # needs_input has no edge: the engine parks the run and resumes brainstorm on answer.
        %{from: "brainstorm", to: "done", on: :succeeded}
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
        %{from: "write_plan", to: "done", on: :succeeded}
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
            "git fetch origin --prune && git checkout -B {branch} origin/main && " <>
              "{relay} card {ref} --json | jq -r '.plan // empty' > plan.md && test -s plan.md"
        },
        %{
          key: "implement",
          type: :agent,
          model: "sonnet",
          effort: "high",
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
          run: "Fix the failing acceptance criteria; keep the suite green."
        },
        %{
          key: "post",
          type: :agent,
          model: "sonnet",
          run: "Post the acceptance checklist and smoke screenshots to card {ref} as one comment."
        },
        %{
          key: "merge",
          type: :shell,
          run:
            "git push -u origin {branch} && url=$(gh pr create --fill --head {branch} --base main) && " <>
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
        %{from: "quality_review", to: "precommit", on: :succeeded, when: :foreach_exhausted},
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
        %{from: "post", to: "merge", on: :succeeded},
        %{from: "merge", to: "done", on: :succeeded}
      ]
    }
  end
end
