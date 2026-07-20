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

  defp section(body, heading) do
    case String.split(body, heading, parts: 2) do
      [_, rest] -> rest
      _ -> nil
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

  test "each reviewer specifies the required shape of the escalation question" do
    for name <- @reviewers do
      body = agent(name)

      assert body =~ "file:line", "#{name}.md must require a file:line reference"
      assert body =~ "quote", "#{name}.md must require the mandating plan text be quoted"

      assert body =~ "Fix the code anyway",
             "#{name}.md must offer the 'fix the code anyway' option"

      assert body =~ "Waive it", "#{name}.md must offer the 'waive it' option"
      assert body =~ "allow_text", "#{name}.md must set allow_text on the question"
    end
  end

  test "the old note-and-continue clauses are replaced, not merely supplemented" do
    refute agent("spec-reviewer") =~ "the human adjudicates"
    refute agent("quality-reviewer") =~ "the human adjudicates"
    refute agent("final-reviewer") =~ "do not block the branch over it"
  end

  test "no agent file contains an unrendered template token" do
    for path <- agent_files() do
      refute File.read!(path) =~ "{relay}",
             "#{path} is a static system prompt and is never rendered — a literal " <>
               "placeholder token would reach the model verbatim"
    end
  end
end
