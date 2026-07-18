defmodule Relay.PlanSkillsTest do
  use ExUnit.Case, async: true

  # exec-plan.md and execute-plan.js were retired by RLY-139 (the Code cutover): the
  # Code stage is now a flow (docs/designs/flows/code.jsonc) run by the server-side
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
      assert doc =~ "bin/relay card"
      assert doc =~ "spec"
    end

    test "writes the plan back to the card", %{doc: doc} do
      assert doc =~ "bin/relay plan"
    end

    test "points onward to /exec-plan", %{doc: doc} do
      assert doc =~ "/exec-plan"
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
end
