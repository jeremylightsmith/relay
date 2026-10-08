defmodule Relay.Agents.EscalationContractTest do
  @moduledoc """
  Pins the plan-mandated-finding escalation contract (RLY-190) into the agent system
  prompts. Those files have no runtime behaviour to unit-test, so this is the only
  automated guard that a future edit doesn't silently drop the contract.

  Assert on stable markers, never on prose wording — editorial polish must not fail.
  """
  use ExUnit.Case, async: true

  @reviewers ~w(spec-reviewer quality-reviewer final-reviewer)
  @agents ["plan-implementer" | @reviewers]

  defp agent(name), do: File.read!(".claude/agents/#{name}.md")

  defp agent_files, do: Path.wildcard(".claude/agents/*.md")

  @escalating_ref ".claude/agents/references/escalating.md"
  @re_review_ref ".claude/agents/references/re-review.md"

  defp section(body, heading) do
    case String.split(body, heading, parts: 2) do
      [_, rest] -> rest
      _ -> nil
    end
  end

  # Prose is hard-wrapped, so a phrase can straddle a line break — collapse whitespace before
  # refuting one, or the refute passes vacuously.
  defp squish(text), do: String.replace(text, ~r/\s+/, " ")

  # Like section/2, but stops at the next `## ` or `### ` heading, so a marker later in the
  # file cannot satisfy (or trip) an assertion about this section by accident.
  defp bounded_section(body, heading) do
    case section(body, heading) do
      nil -> nil
      rest -> rest |> String.split(~r/\n\#{2,3} /, parts: 2) |> hd()
    end
  end

  test "every agent in the escalation contract routes escalation through needs-input" do
    for name <- @agents do
      assert agent(name) =~ "needs-input",
             "#{name}.md must name the `needs-input` escalation route"
    end
  end

  test "each reviewer offers Escalate as a third verdict in its Decide section" do
    for name <- @reviewers do
      decide = section(agent(name), "## Decide")
      assert decide, "#{name}.md must have a `## Decide` section"

      assert decide =~ "**Escalate**",
             "#{name}.md's `## Decide` must offer Escalate alongside Approve/Pass and Fix"
    end
  end

  test "each reviewer points at the escalation mechanics from Escalate sparingly" do
    for name <- @reviewers do
      body = agent(name)

      assert section(body, "## Decide") =~ "**Escalate**",
             "#{name}.md's `## Decide` must still offer Escalate"

      assert body =~ "needs-input", "#{name}.md must still name the `needs-input` route"
      assert body =~ "outcome contract", "#{name}.md must still point at the outcome contract"

      sparingly = bounded_section(body, "### Escalate sparingly")
      assert sparingly, "#{name}.md must have a `### Escalate sparingly` section"

      assert sparingly =~ @escalating_ref,
             "#{name}.md's `### Escalate sparingly` must point at #{@escalating_ref}"
    end
  end

  test "the escalation reference carries the CONTENT of the escalation question" do
    assert File.exists?(@escalating_ref), "#{@escalating_ref} must exist"
    body = File.read!(@escalating_ref)

    for marker <- ["file:line", "verbatim", "Fix the code anyway", "Waive it"] do
      assert body =~ marker, "#{@escalating_ref} must carry #{inspect(marker)}"
    end
  end

  test "no reviewer restates the escalation mechanics inline" do
    for name <- @reviewers do
      refute squish(agent(name)) =~ "In short —",
             "#{name}.md restates #{@escalating_ref} — point at it instead"
    end
  end

  test "each reviewer's SECOND-look section points at the re-review reference" do
    for name <- @reviewers do
      second = bounded_section(agent(name), "## When this is your SECOND look")
      assert second, "#{name}.md must have a `## When this is your SECOND look` section"

      assert second =~ @re_review_ref,
             "#{name}.md's SECOND-look section must point at #{@re_review_ref}"

      for marker <- ["Do not re-run your checklist", "Never re-raise a finding the fixer rebutted"] do
        refute squish(second) =~ marker,
               "#{name}.md restates #{inspect(marker)} — it lives only in #{@re_review_ref}"
      end
    end
  end

  test "the re-review reference carries the shared re-review core" do
    assert File.exists?(@re_review_ref), "#{@re_review_ref} must exist"
    body = File.read!(@re_review_ref)

    for marker <- ["Do not re-run your checklist", "rebutted", "re-review"] do
      assert body =~ marker, "#{@re_review_ref} must carry #{inspect(marker)}"
    end
  end

  test "every references/ path an agent file names exists" do
    for path <- agent_files(),
        ref <- Regex.scan(~r{\.claude/agents/references/[\w.-]+\.md}, File.read!(path)),
        ref = hd(ref) do
      assert File.exists?(ref), "#{path} points at #{ref}, which does not exist"
    end
  end

  test "no agent file re-states the questions SCHEMA the outcome contract injects" do
    # The envelope — the array, `allow_text`, the heredoc, the command — is appended to every
    # agent prompt by OUTCOME_CONTRACT. Six files used to hand-carry their own copy, which is
    # how a schema drifts from the validator that enforces it. Each file still specifies what
    # its question should SAY; only the shape is deferred.
    for path <- agent_files() do
      body = File.read!(path)

      refute body =~ "allow_text",
             "#{path} restates the questions schema — the outcome contract injects it, and a " <>
               "second copy is what drifts"

      refute body =~ "<<'JSON'",
             "#{path} carries its own questions heredoc — point at the outcome contract instead"
    end
  end

  test "the files that escalate point at the injected contract for the shape" do
    for name <- @agents do
      assert agent(name) =~ "outcome contract",
             "#{name}.md must send the reader to the injected outcome contract for the " <>
               "command and the payload shape"
    end
  end

  test "the old note-and-continue clauses are replaced, not merely supplemented" do
    refute agent("spec-reviewer") =~ "the human adjudicates"
    refute agent("quality-reviewer") =~ "the human adjudicates"
    refute agent("final-reviewer") =~ "do not block the branch over it"
  end

  test "the implementer declares only statuses the runner understands" do
    body = agent("plan-implementer")

    refute body =~ "BLOCKED",
           "plan-implementer.md must not declare a BLOCKED status — the runner reads only " <>
             "succeeded | failed | needs_input"

    refute body =~ "NEEDS_CONTEXT",
           "plan-implementer.md must not declare a NEEDS_CONTEXT status"
  end

  test "the implementer honours a human-authorized deviation from the plan" do
    sent_back = section(agent("plan-implementer"), "## If a reviewer sent you back")
    assert sent_back, "plan-implementer.md must have an `## If a reviewer sent you back` section"

    assert sent_back =~ "authorization",
           "it must say a finding carrying a quoted human authorization is special"

    # RE357: the per-task spec is the task's body, fetched by id — no longer plan.md.
    assert sent_back =~ "outranks the task's body",
           "it must say that authorization outranks the task's body for this task"

    assert sent_back =~ "./relay task show <ref> <id>",
           "it must say where that body comes from"
  end

  test "no agent file contains an unrendered template token" do
    for path <- agent_files() do
      refute File.read!(path) =~ "{relay}",
             "#{path} is a static system prompt and is never rendered — a literal " <>
               "placeholder token would reach the model verbatim"
    end
  end

  test "the escalation command the agent files point at renders a real ref" do
    contract =
      "relay"
      |> File.read!()
      |> section("OUTCOME_CONTRACT = \"\"\"")

    assert contract, "./relay must define OUTCOME_CONTRACT"
    [contract | _] = String.split(contract, "\"\"\"", parts: 2)

    assert contract =~ "needs-input {ref}",
           "the outcome contract's needs-input command must interpolate {ref} — the agent " <>
             "files tell agents to copy it verbatim, so a literal <ref> placeholder would " <>
             "reach the model and the command would not run"

    refute contract =~ "<ref>",
           "the outcome contract must not carry an unrendered <ref> placeholder"
  end

  test "the runner architecture page records the escalation re-entry decision" do
    runner = File.read!("docs/architecture/runner.md")
    subsection = section(runner, "#### Escalating a plan-mandated finding")

    assert subsection,
           "runner.md must document the escalation contract under the agent-node section"

    assert subsection =~ "needs-input"

    assert subsection =~ "authoritative",
           "it must state that the human's answer is authoritative for the rest of the run"

    assert subsection =~ "`branch` node",
           "it must give the reason the plan-edit path was rejected: plan.md is written once " <>
             "by the branch node"

    assert subsection =~ "sub_tasks",
           "it must state that sub_tasks are seeded only at run start"
  end

  test "the runner architecture page describes the references/ split the agent files use" do
    subsection =
      "docs/architecture/runner.md"
      |> File.read!()
      |> section("#### Escalating a plan-mandated finding")

    assert subsection, "runner.md must keep the RLY-190 subsection"

    for ref <- [@escalating_ref, @re_review_ref] do
      assert subsection =~ Path.relative_to(ref, ".claude/agents"),
             "runner.md must say what lives in #{ref}"
    end

    assert subsection =~ "claude --version",
           "runner.md must cite the claude version the reference-loading probe ran against"

    refute squish(subsection) =~ "would simply never reach the model",
           "runner.md still claims a references/ file never reaches the model — the probe " <>
             "showed an agent reads it at runtime"
  end
end
