defmodule Relay.PlanSkillsTest do
  use ExUnit.Case, async: true

  @write_plan Path.join([File.cwd!(), ".claude", "commands", "write-plan.md"])
  @exec_plan Path.join([File.cwd!(), ".claude", "commands", "exec-plan.md"])
  @execute_plan_js Path.join([File.cwd!(), ".claude", "workflows", "execute-plan.js"])

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

    test "extracts the card's plan with jq, not an undeclared python3 dependency", %{doc: doc} do
      assert doc =~ "jq -r"
      refute doc =~ "python3"
    end

    test "resume note preserves on-disk plan.md progress instead of unconditionally re-materializing",
         %{doc: doc} do
      assert doc =~ "progress is tracked"
      assert doc =~ "only re-materialize"
      refute doc =~ "re-materialize `plan.md` from the card and relaunch"
    end

    test "does not delete plan.md unconditionally right after launch, before any status is known",
         %{doc: doc} do
      refute doc =~ "however it ends"
    end

    test "only deletes plan.md on the successful ready completion, after the status is known",
         %{doc: doc} do
      {on_completion_idx, _} = :binary.match(doc, "## On completion")
      {rm_idx, _} = :binary.match(doc, "rm -f plan.md")
      assert rm_idx > on_completion_idx
    end

    test "keeps plan.md on every halt status so a resumed run finds its completed-task progress",
         %{doc: doc} do
      assert doc =~ "leave `plan.md` in place"
    end

    test "enumerates the acceptance statuses so the runner sentinel can gate on them", %{doc: doc} do
      assert doc =~ "acceptance-failed"
      assert doc =~ "acceptance-blocked"
    end
  end

  describe "execute-plan.js gates the acceptance phase on whether the criteria fetch actually succeeded" do
    setup do
      {:ok, doc: File.read!(@execute_plan_js)}
    end

    test "the criteria probe distinguishes a fetch error from a genuinely empty field", %{doc: doc} do
      assert doc =~ "enum: ['present', 'absent', 'error']"
    end

    test "a probe fetch error is routed to blocked, never silently treated as no criteria", %{doc: doc} do
      assert doc =~ "probe.result === 'error'"
      assert doc =~ "verdict: 'blocked'"
    end

    test "a missing probe result (framework failure) is also treated as blocked, not skipped", %{doc: doc} do
      assert doc =~ "!probe || probe.result === 'error'"
    end

    test "the acceptance fix-loop has no redundant done flag mirroring the smoke loop's plain breaks",
         %{doc: doc} do
      refute doc =~ "acceptDone"
    end
  end
end
