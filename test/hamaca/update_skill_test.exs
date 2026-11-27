defmodule Hamaca.UpdateSkillTest do
  use ExUnit.Case, async: true

  @skill Path.join([File.cwd!(), ".claude", "skills", "hamaca-update", "SKILL.md"])

  setup do
    {:ok, doc: File.read!(@skill)}
  end

  test "the skill directory holds exactly SKILL.md — the scaffold build copies nothing else" do
    assert File.ls!(Path.dirname(@skill)) == ["SKILL.md"]
  end

  test "declares its name in frontmatter", %{doc: doc} do
    assert doc =~ ~r/^name: hamaca-update$/m
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

      assert step5 =~ "Tooling changed — run `/hamaca-doctor` to check your factory against it."
      assert step5 =~ "wrote at least one file"
    end

    test "is skipped when --check said current", %{doc: doc} do
      [_, rest] = String.split(doc, "### 5. Nudge toward the doctor\n", parts: 2)
      [step5, _] = String.split(rest, ~r/^## /m, parts: 2)
      step5 = String.replace(step5, ~r/\s+/, " ")

      assert step5 =~ "Skip it when step 1's `--check` said current"
    end
  end

  # RE478: the source is the Hamaca-named skill. RE482 closed the compatibility window, so the
  # thin `relay-update` alias is gone.
  describe "the Hamaca rename (RE478)" do
    @alias_skill Path.join([File.cwd!(), ".claude", "skills", "relay-update", "SKILL.md"])

    test "the hamaca-update source speaks only the Hamaca names", %{doc: doc} do
      assert doc =~ ~r/^name: hamaca-update$/m

      for stale <- ["./relay", ".relay/", "relay.md", "RELAY_"] do
        refute doc =~ stale, "hamaca-update still says #{stale}"
      end

      # RE482: the runner surface speaks Hamaca, never the Relay brand.
      refute doc =~ "# Relay Update"
      refute doc =~ ~r/\bRelay\b/
    end

    test "the relay-update alias skill is retired (RE482)" do
      refute File.exists?(Path.dirname(@alias_skill))
    end
  end
end
