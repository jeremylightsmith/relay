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

    test "/relay-doctor counts the task verbs as sub_tasks evidence" do
      doc = File.read!(@doctor)
      assert doc =~ "| `sub_tasks` | `relay tasks add`"
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
end
