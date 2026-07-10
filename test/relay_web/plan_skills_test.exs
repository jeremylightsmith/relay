defmodule Relay.PlanSkillsTest do
  use ExUnit.Case, async: true

  @write_plan Path.join([File.cwd!(), ".claude", "commands", "write-plan.md"])
  @exec_plan Path.join([File.cwd!(), ".claude", "commands", "exec-plan.md"])

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
  end

  describe "exec-plan preflights on the card plan and materializes it transiently" do
    setup do
      {:ok, doc: File.read!(@exec_plan)}
    end

    test "preflight reads the card and requires a non-empty plan", %{doc: doc} do
      assert doc =~ "bin/relay card"
      assert doc =~ "non-empty"
    end

    test "materializes the card plan into a transient plan.md and deletes it after", %{doc: doc} do
      assert doc =~ "plan.md"
      assert doc =~ "rm -f plan.md"
    end

    test "still launches the unchanged execute-plan.js workflow", %{doc: doc} do
      assert doc =~ "execute-plan.js"
    end
  end
end
