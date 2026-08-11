defmodule Relay.SetupSkillTest do
  @moduledoc """
  RE304. `/relay-setup` is the one Relay artifact a fresh project has, so it must be able to
  bootstrap from *only* itself. The trap this pins: the step that installs the other four
  `relay-*` skills cannot itself be one of them — the `Skill` tool resolves names from the
  session's installed skills, and a file written mid-session is not in that list either.
  """
  use ExUnit.Case, async: true

  @skill Path.join([File.cwd!(), ".claude", "skills", "relay-setup", "SKILL.md"])

  setup do
    {:ok, doc: File.read!(@skill)}
  end

  test "the skill directory holds exactly SKILL.md — the scaffold build copies nothing else" do
    assert File.ls!(Path.dirname(@skill)) == ["SKILL.md"]
  end

  test "declares its name in frontmatter", %{doc: doc} do
    assert doc =~ ~r/^name: relay-setup$/m
  end

  test "installs the skills with the command, never by invoking the skill it is installing", %{doc: doc} do
    [_, step3] = String.split(doc, "## Step 3", parts: 2)
    [step3, _] = String.split(step3, "## Step 4", parts: 2)

    assert step3 =~ "bin/relay update --json"
    refute String.replace(step3, ~r/\s+/, " ") =~ "Invoke **`/relay-update`** (via the `Skill` tool)"
  end

  test "tells the human to restart the session before /relay-onboard is reachable", %{doc: doc} do
    [_, step4] = String.split(doc, "## Step 4", parts: 2)

    assert step4 =~ "Restart Claude Code"
    assert step4 =~ "/relay-onboard"
  end
end
