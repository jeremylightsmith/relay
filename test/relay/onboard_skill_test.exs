defmodule Relay.OnboardSkillTest do
  use ExUnit.Case, async: true

  @skill Path.join([File.cwd!(), ".claude", "skills", "relay-onboard", "SKILL.md"])

  setup do
    {:ok, doc: File.read!(@skill)}
  end

  test "the skill directory holds exactly SKILL.md — the scaffold build copies nothing else" do
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

    for allowed <- ["`.claude/`", "`.relay/executor.json`", "flow documents"] do
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

  # RE304: the scaffold no longer ships `writing-skills`, so pointing at it from a skill that
  # DOES ship would dangle in every scaffolded project. The authoring guidance is inlined
  # instead — assert on that, and assert the dead pointer stays gone.
  test "inlines how to author a missing step, or drops the node", %{doc: doc} do
    refute doc =~ "writing-skills"
    assert doc =~ ".claude/agents/<name>.md"
    assert doc =~ ".claude/skills/<name>/SKILL.md"
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

  test "Phase 3's plan actually authors .relay/executor.json when missing", %{doc: doc} do
    [_, phase3_and_later] = String.split(doc, "## Phase 3", parts: 2)
    [phase3, _] = String.split(phase3_and_later, "## Phase 4", parts: 2)

    assert phase3 =~ ".relay/executor.json"
    assert phase3 =~ "author it for this repo"
  end

  test "onboarding does not author relay.md — the scaffold serves it", %{doc: doc} do
    # relay.md joined Scaffold.items/0, so `bin/relay update` installs and repairs it. If this
    # skill still authored one per repo, the next update would silently overwrite that work.
    assert "relay.md" in Relay.Scaffold.items()

    [_, phase3_and_later] = String.split(doc, "## Phase 3", parts: 2)
    [phase3, _] = String.split(phase3_and_later, "## Phase 4", parts: 2)

    refute phase3 =~ "relay.md"
  end

  test "the floor check preamble does not claim the scaffold floor is never a mutation", %{
    doc: doc
  } do
    [_, phase0_and_later] = String.split(doc, "## Phase 0", parts: 2)
    [phase0, _] = String.split(phase0_and_later, "## Phase 1", parts: 2)

    refute phase0 =~ "neither is something a skill can fix"
    assert phase0 =~ "a skill cannot mint a key"
    assert phase0 =~ "self-heals via `bin/relay update`"
  end

  # The missing `relay-*` skill may *be* `relay-update`, and the Skill tool cannot resolve a
  # name that is not installed — so the floor must repair itself with the command.
  test "the scaffold floor repairs missing skills with the command, not the Skill tool", %{doc: doc} do
    [_, phase0_and_later] = String.split(doc, "## Phase 0", parts: 2)
    [phase0, _] = String.split(phase0_and_later, "## Phase 1", parts: 2)

    assert phase0 =~ "bin/relay update --json"
    refute String.replace(phase0, ~r/\s+/, " ") =~ "run `/relay-update` (via the `Skill` tool)"
  end

  test "the sibling-file mistake names the current scaffold mechanism, not the retired publish task",
       %{doc: doc} do
    refute doc =~ "the publish task"
    assert doc =~ "Scaffold.items"
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
