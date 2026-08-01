defmodule Relay.OnboardSkillTest do
  use ExUnit.Case, async: true

  @skill Path.join([File.cwd!(), ".claude", "skills", "relay-onboard", "SKILL.md"])

  setup do
    {:ok, doc: File.read!(@skill)}
  end

  test "the skill directory holds exactly SKILL.md — the publish task copies nothing else" do
    assert File.ls!(Path.dirname(@skill)) == ["SKILL.md"]
  end

  test "declares its name in frontmatter", %{doc: doc} do
    assert doc =~ ~r/^name: relay-onboard$/m
  end

  test "heads every phase of the spine", %{doc: doc} do
    for phase <- ["Floor check", "Detect", "Choose the path", "Plan", "Apply", "Enable"] do
      assert doc =~ ~r/^## Phase \d+ — .*#{Regex.escape(phase)}/m
    end
  end

  test "forbids running from a flow node", %{doc: doc} do
    assert doc =~ "Never run this from a flow node"
  end

  test "names its blast radius and what it excludes", %{doc: doc} do
    assert doc =~ "**Blast radius:**"

    for allowed <- ["`.claude/`", "`relay.md`", "`.relay/executor.json`", "flow documents"] do
      assert doc =~ allowed
    end

    assert doc =~ "**Never** app code, git branches, commits, or cards."
  end

  test "consumes the doctor rather than restating its checks", %{doc: doc} do
    assert doc =~ "/relay-doctor"
    assert doc =~ "adds no checks of its own"
    refute doc =~ ~r/\bbin\/relay doctor\b/
  end

  test "imports the executor's own capability resolver", %{doc: doc} do
    assert doc =~ "collect_capabilities()"
  end

  test "makes the path an explicit user choice", %{doc: doc} do
    assert doc =~ "never a hidden inference"

    for path <- ["**Seed**", "**Adopt**", "**Hybrid**"] do
      assert doc =~ path
    end
  end

  test "hands a missing step to writing-skills or drops the node", %{doc: doc} do
    assert doc =~ "`writing-skills`"
    assert doc =~ "drop the node"
  end

  test "terminates on zero errors and reports a stall instead of looping", %{doc: doc} do
    assert doc =~ "zero errors"
    assert doc =~ "two consecutive passes"
  end

  test "reports warnings without chasing them", %{doc: doc} do
    assert doc =~ "Warnings are reported, not chased."
  end

  test "enables flows via flow-push, one confirmation per flow, only when green", %{doc: doc} do
    assert doc =~ "flow-push"
    assert doc =~ "one confirmation per flow"
    assert doc =~ "Never offer to enable a flow that still has errors"
  end

  describe "discoverability" do
    test "relay.md's Setup section names the skill" do
      assert File.read!("relay.md") =~ "/relay-onboard"
    end

    test "AGENTS.md names it under Skill discipline" do
      assert File.read!("AGENTS.md") =~ "/relay-onboard"
    end
  end
end
