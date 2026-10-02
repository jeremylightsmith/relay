defmodule Relay.UpdateSkillTest do
  use ExUnit.Case, async: true

  @skill Path.join([File.cwd!(), ".claude", "skills", "relay-update", "SKILL.md"])

  setup do
    {:ok, doc: File.read!(@skill)}
  end

  test "the skill directory holds exactly SKILL.md — the scaffold build copies nothing else" do
    assert File.ls!(Path.dirname(@skill)) == ["SKILL.md"]
  end

  test "declares its name in frontmatter", %{doc: doc} do
    assert doc =~ ~r/^name: relay-update$/m
  end

  # RE369: new tooling can carry a factory migration the repo's own agents haven't picked up,
  # and nothing else tells the human to look.
  describe "the doctor nudge" do
    test "is the checklist's last step", %{doc: doc} do
      steps = Regex.scan(~r/^### (\d+)\. (.+)$/m, doc, capture: :all_but_first)

      assert List.last(steps) == ["5", "Nudge toward the doctor"]
    end

    test "ends with the exact line once files were written", %{doc: doc} do
      [_, rest] = String.split(doc, "### 5. Nudge toward the doctor\n", parts: 2)
      [step5, _] = String.split(rest, ~r/^## /m, parts: 2)
      step5 = String.replace(step5, ~r/\s+/, " ")

      assert step5 =~ "Tooling changed — run `/relay-doctor` to check your factory against it."
      assert step5 =~ "wrote at least one file"
    end

    test "is skipped when --check said current", %{doc: doc} do
      [_, rest] = String.split(doc, "### 5. Nudge toward the doctor\n", parts: 2)
      [step5, _] = String.split(rest, ~r/^## /m, parts: 2)
      step5 = String.replace(step5, ~r/\s+/, " ")

      assert step5 =~ "Skip it when step 1's `--check` said current"
    end
  end
end
