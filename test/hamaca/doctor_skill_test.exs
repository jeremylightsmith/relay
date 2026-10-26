defmodule Hamaca.DoctorSkillTest do
  use ExUnit.Case, async: true

  @skill Path.join([File.cwd!(), ".claude", "skills", "hamaca-doctor", "SKILL.md"])

  setup do
    {:ok, doc: File.read!(@skill)}
  end

  # Markdown wraps prose at ~100 columns, so phrase assertions run on whitespace-collapsed text.
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  # The body of a `## ` section, up to the next `## ` heading (`###` subheadings stay inside).
  defp section(doc, heading) do
    [_, rest] = String.split(doc, heading <> "\n", parts: 2)
    rest |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  defp migration(doc) do
    [_, rest] = String.split(section(doc, "## Factory migrations"), "### Migration `tasks-cutover`", parts: 2)
    rest
  end

  defp subsection(text, heading) do
    [_, rest] = String.split(text, heading <> "\n", parts: 2)
    rest |> String.split(~r/^####? /m, parts: 2) |> hd()
  end

  test "the skill directory holds exactly SKILL.md — the scaffold build copies nothing else" do
    assert File.ls!(Path.dirname(@skill)) == ["SKILL.md"]
  end

  test "declares its name in frontmatter", %{doc: doc} do
    assert doc =~ ~r/^name: hamaca-doctor$/m
  end

  describe "## Factory migrations" do
    test "is a top-level section", %{doc: doc} do
      assert doc =~ ~r/^## Factory migrations$/m
    end

    test "states the generic shape once, so later migrations append an entry", %{doc: doc} do
      body = flat(section(doc, "## Factory migrations"))

      for part <- ["**id**", "**why**", "**detection rules**", "**recipe**", "**verify**"] do
        assert body =~ part
      end

      for state <- ["**pending**", "**applied**", "**n/a**"] do
        assert body =~ state
      end

      assert body =~ "No migration is ever applied automatically."
    end

    test "carries a tasks-cutover entry with detect, both recipes and verify", %{doc: doc} do
      assert section(doc, "## Factory migrations") =~ ~r/^### Migration `tasks-cutover` \(RE357\)$/m

      for heading <- ["#### Detect", "#### Plan-side recipe", "#### Exec-side recipe", "#### Verify"] do
        assert migration(doc) =~ ~r/^#{Regex.escape(heading)}$/m
      end
    end

    test "detection covers the planner, the task nodes, legacy spellings and the audit", %{doc: doc} do
      detect = flat(subsection(migration(doc), "#### Detect"))

      assert detect =~ "relay tasks add"
      assert detect =~ "relay task show"
      assert detect =~ "`card.sub_tasks`"
      assert detect =~ "`{sub_task_id}`"
      assert detect =~ "`planner_not_migrated`"
      # Rule 4 alone is stale history, not a pending migration.
      assert detect =~ "If rules 1–3 all pass, report the migration **applied**"
    end

    test "the plan-side recipe writes a header, clears stale tasks, adds them in one call", %{doc: doc} do
      plan_side = flat(subsection(migration(doc), "#### Plan-side recipe"))

      for token <- [
            "./hamaca plan <ref> @header.md",
            "## Verification",
            "./hamaca tasks list <ref> --json",
            "./hamaca task rm <ref> <id>",
            ~s(./hamaca tasks add <ref> --task "<title>" @task1.md),
            "ONE call",
            "./hamaca task show <ref> <id>",
            "$HAMACA_NODE_SCRATCH",
            ~s(writes: ["plan", "tasks"])
          ] do
        assert plan_side =~ token
      end
    end

    test "the exec-side recipe reads tasks by id and the plan only for its header", %{doc: doc} do
      exec_side = flat(subsection(migration(doc), "#### Exec-side recipe"))

      for token <- [
            ~s(foreach: "card.tasks"),
            ~s(reads: ["tasks"]),
            "{relay} task show {ref} {task_id}",
            "`$HAMACA_PLAN` **only** for the header",
            "## Task N"
          ] do
        assert exec_side =~ token
      end
    end

    test "verify re-runs detection and names the next-card signals", %{doc: doc} do
      verify = flat(subsection(migration(doc), "#### Verify"))

      assert verify =~ "**applied**"
      assert verify =~ "tasks_from_plan"
      assert verify =~ "planner_not_migrated"
    end

    test "names the reference implementation as a worked example", %{doc: doc} do
      body = migration(doc)

      assert body =~ ".claude/commands/write-plan.md"
      assert body =~ "docs/designs/flows/code.json"
    end
  end

  describe "check 8 offers the migration before removing a declaration" do
    test "the finding's fix line names the migration", %{doc: doc} do
      assert flat(doc) =~ "**Check 8 defers to a migration that covers it.**"
      assert flat(doc) =~ ~s(reads "apply migration `tasks-cutover`")
    end

    test "the dialogue offers the migration first and removal only on decline", %{doc: doc} do
      fixing = flat(section(doc, "## Fixing, in dialogue"))

      assert fixing =~ "offer the migration **first**"
      assert fixing =~ "Removing the declaration is offered only if the human declines the migration."
      assert fixing =~ "`[apply / skip]`"
    end

    test "the common mistake no longer steers toward removing a covered declaration", %{doc: doc} do
      mistakes = flat(section(doc, "## Common mistakes"))

      assert mistakes =~ "fix the skill rather than removing the declaration"
      assert mistakes =~ "**Applying a migration without asking**"
    end

    test "an agent node's own run prompt counts as evidence", %{doc: doc} do
      assert flat(doc) =~ "An **agent** node's own `run` prompt text"
    end
  end

  describe "board health and the report" do
    test "the audit table has a planner_not_migrated row pointing at tasks-cutover", %{doc: doc} do
      table = section(doc, "## Board health (the audit)")

      assert table =~ ~r/^\| `planner_not_migrated` \(WARNING\) \|.*`tasks-cutover`.*\|$/m
    end

    test "the summary line counts pending migrations", %{doc: doc} do
      assert flat(section(doc, "## The report")) =~ "N errors, M warnings, K migrations pending across F flows"
    end

    test "the report shows a migrations section with its own status word", %{doc: doc} do
      report = section(doc, "## The report")

      assert report =~ "factory migrations"
      assert report =~ ~r/^\s+MIGRATION tasks-cutover/m
    end
  end

  # RE367 made `tasks` canonical. The legacy spellings live in exactly one place — the
  # tasks-cutover detection rule that hunts for them in repo flow files.
  test "outside the legacy-spellings rule, the skill speaks only the canonical tasks names",
       %{doc: doc} do
    [before, rest] = String.split(doc, "3. **Legacy spellings in a repo flow file.**", parts: 2)
    [_rule3, after_rule] = String.split(rest, "4. **The audit says so.**", parts: 2)

    refute before <> after_rule =~ ~r/sub[_-]tasks?/i
  end

  # RE478: the source is the Hamaca-named skill; `relay-doctor` stays only as a thin alias for the
  # compatibility window (the legacy scaffold layout generates its full copy from this source).
  describe "the Hamaca rename (RE478)" do
    @alias_skill Path.join([File.cwd!(), ".claude", "skills", "relay-doctor", "SKILL.md"])

    test "the hamaca-doctor source speaks only the Hamaca names", %{doc: doc} do
      assert doc =~ ~r/^name: hamaca-doctor$/m

      for stale <- ["./relay", ".relay/", "relay.md", "RELAY_"] do
        refute doc =~ stale, "hamaca-doctor still says #{stale}"
      end
    end

    test "relay-doctor is an alias: its own name, the same description, a one-line body",
         %{doc: doc} do
      alias_doc = File.read!(@alias_skill)

      assert alias_doc =~ ~r/^name: relay-doctor$/m
      assert frontmatter(alias_doc, "description") == frontmatter(doc, "description")
      assert alias_doc |> body() |> String.trim() == "Renamed: use /hamaca-doctor."
    end

    test "the alias directory holds exactly SKILL.md" do
      assert File.ls!(Path.dirname(@alias_skill)) == ["SKILL.md"]
    end
  end

  defp frontmatter(doc, key) do
    [_, value] = Regex.run(~r/^#{key}: (.*)$/m, doc)
    value
  end

  defp body(doc) do
    ["", _frontmatter, body] = String.split(doc, ~r/^---$/m, parts: 3)
    body
  end
end
