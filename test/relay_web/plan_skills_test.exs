defmodule Relay.PlanSkillsTest do
  use ExUnit.Case, async: true

  # exec-plan.md and execute-plan.js were retired by RLY-139 (the Code cutover): the
  # Code stage is now a flow (docs/designs/flows/code.json) run by the server-side
  # scheduler, not a `/exec-plan` command. Their describe blocks retired with them —
  # see test/relay/runs/code_flow_e2e_test.exs for the flow's coverage.
  @write_plan Path.join([File.cwd!(), ".claude", "commands", "write-plan.md"])

  describe "write-plan reads the spec from the card and writes the plan to the card" do
    setup do
      {:ok, doc: File.read!(@write_plan)}
    end

    test "takes the card ref from $ARGUMENTS", %{doc: doc} do
      assert doc =~ "$ARGUMENTS"
    end

    test "reads the spec from the card", %{doc: doc} do
      assert doc =~ "./relay card"
      assert doc =~ "spec"
    end

    test "writes the plan back to the card", %{doc: doc} do
      assert doc =~ "./relay plan"
    end

    test "no longer points onward to the retired /exec-plan command", %{doc: doc} do
      refute doc =~ "/exec-plan"
    end

    test "explains that the Code flow now picks the card up automatically", %{doc: doc} do
      assert doc =~ "Plan:Done"
      assert doc =~ "Settings"
    end

    test "points back to /brainstorm when the card has no approved spec", %{doc: doc} do
      assert doc =~ "/brainstorm"
    end

    test "no longer resolves the spec from a shared docs/superpowers/specs path", %{doc: doc} do
      refute doc =~ "docs/superpowers/specs"
    end

    test "makes the plan cover the card's acceptance criteria without copying them in", %{doc: doc} do
      assert doc =~ "acceptance_criteria"
      assert doc =~ "acceptance-tester"
    end
  end

  @agents_dir Path.join([File.cwd!(), ".claude", "agents"])
  @doctor Path.join([File.cwd!(), ".claude", "skills", "relay-doctor", "SKILL.md"])

  describe "the Code flow's agents fetch their task by id (RE357)" do
    for name <- ~w(plan-implementer spec-reviewer quality-reviewer final-fixer) do
      test "#{name} fetches the task body with relay task show" do
        doc = File.read!(Path.join(@agents_dir, unquote(name) <> ".md"))
        assert doc =~ "./relay task show <ref> <id>"
        refute doc =~ "## Task N"
      end
    end

    test "final-reviewer reads the whole task list, then bodies as needed" do
      doc = File.read!(Path.join(@agents_dir, "final-reviewer.md"))
      assert doc =~ "./relay tasks list <ref>"
      assert doc =~ "./relay task show <ref> <id>"
      refute doc =~ "## Task N"
    end

    test "/relay-doctor counts the task verbs as tasks evidence" do
      doc = File.read!(@doctor)
      assert doc =~ "| `tasks` | `relay tasks add` |"
      assert doc =~ "`relay task show`"
      assert doc =~ "`relay tasks list`"
    end
  end

  describe "write-plan writes a header plus tasks, never a document to parse (RE357)" do
    setup do
      {:ok, doc: File.read!(@write_plan)}
    end

    test "writes every task in ONE relay tasks add call", %{doc: doc} do
      assert doc =~ ~s(./relay tasks add <ref> --task "<title>" @)
    end

    test "writes only the header with relay plan", %{doc: doc} do
      assert doc =~ "./relay plan <ref> @"
      assert doc =~ "header"
    end

    test "drops the machine-parsed heading contract and the checkbox-flipping note", %{doc: doc} do
      refute doc =~ "## Task N"
      refute doc =~ "PlanTasks"
      refute doc =~ "em-dash"
      refute doc =~ "flips them"
    end

    test "clears stale tasks before a re-plan so it never appends duplicates", %{doc: doc} do
      assert doc =~ "./relay task rm <ref> <id>"
      assert doc =~ "appends"
    end

    test "self-review checks the written task list", %{doc: doc} do
      assert doc =~ "./relay tasks list <ref>"
    end
  end

  describe "plans are contract + behaviors, not code (RE378)" do
    test "write-plan's task body is a contract + behaviors, in named sections" do
      doc = File.read!(@write_plan)

      for section <- [
            "**Files**",
            "**Interfaces**",
            "**Consumes**",
            "**Produces**",
            "**Patterns to follow**",
            "**Test scenarios**",
            "**Risks / gotchas**",
            "**Steps**",
            "**Deliverable**"
          ] do
        assert doc =~ section, "write-plan.md must name the #{section} task-body section"
      end

      assert doc =~ "Given/When/Then"
    end

    test "write-plan forbids code beyond the contract" do
      doc = File.read!(@write_plan)

      assert doc =~ "No function bodies, no test code, no fenced implementation blocks"
      refute doc =~ "ACTUAL test code"
      refute doc =~ "diff target"
    end

    test "write-plan reconnoitres the repo before authoring, recording file:line pointers" do
      doc = File.read!(@write_plan)

      {recon, _} = :binary.match(doc, "**Reconnaissance.**")
      {author, _} = :binary.match(doc, "**Author the plan**")
      assert recon < author, "the reconnaissance step must come before authoring"

      assert doc =~ "file:line"
      assert doc =~ "docs/architecture/"
      assert doc =~ "magic value is defined exactly once"
    end

    test "write-plan's self-review checks pointers and scenario coverage" do
      [_, self_review] = String.split(File.read!(@write_plan), "### Self-review", parts: 2)
      [self_review | _] = String.split(self_review, "## Writing it to the card", parts: 2)

      assert self_review =~ "pointer"
      assert self_review =~ "scenario"
      assert self_review =~ "acceptance criterion"
      assert self_review =~ "no code"
    end

    test "plan-implementer writes its tests from the task's scenarios" do
      doc = File.read!(Path.join(@agents_dir, "plan-implementer.md"))

      assert doc =~ "The tests come from the scenarios"
      assert doc =~ "Given/When/Then"
      assert doc =~ "at least one test per"
      assert doc =~ "Produces signatures and data shapes are binding"
      assert doc =~ "Scenario → test map"
      refute doc =~ "real code and tests"
      refute doc =~ "code as written"
    end

    test "plan-implementer escalates a contradictory or impossible scenario" do
      doc = File.read!(Path.join(@agents_dir, "plan-implementer.md"))

      assert doc =~ "Escalate, don't guess"
      assert doc =~ "Consumes signature doesn't exist"
    end

    test "spec-reviewer checks scenarios, interfaces, files and nothing extra" do
      doc = File.read!(Path.join(@agents_dir, "spec-reviewer.md"))

      for check <- ["**Scenarios:**", "**Interfaces:**", "**Files:**", "**Nothing extra:**"] do
        assert doc =~ check, "spec-reviewer.md must check #{check}"
      end

      assert doc =~ "Produces"
      assert doc =~ "scenario → test"
      refute doc =~ "line-by-line"
    end

    test "the implement and spec_review models are unchanged" do
      assert File.read!(Path.join(@agents_dir, "plan-implementer.md")) =~ ~r/^model: opus$/m
      assert File.read!(Path.join(@agents_dir, "spec-reviewer.md")) =~ ~r/^model: sonnet$/m
    end
  end
end
