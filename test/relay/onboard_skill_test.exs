defmodule Relay.OnboardSkillTest do
  @moduledoc """
  The static contract for `/relay-onboard` (RE445): a loop over the board's guided-setup
  checklist, sub-steps 5.1–5.8, driven through `./relay setup status|report`. The skill asks
  questions, so it is never run from a flow node — this test is the check.
  """
  use ExUnit.Case, async: true

  alias Relay.Setup

  @skill Path.join([File.cwd!(), ".claude", "skills", "relay-onboard", "SKILL.md"])

  setup do
    {:ok, doc: File.read!(@skill)}
  end

  # Scenario 1
  test "the skill directory holds exactly SKILL.md — the scaffold build copies nothing else" do
    assert File.ls!(Path.dirname(@skill)) == ["SKILL.md"]
  end

  test "declares its name in frontmatter", %{doc: doc} do
    assert doc =~ ~r/^name: relay-onboard$/m
  end

  # Scenario 2
  test "names every onboard sub-step from the catalog", %{doc: doc} do
    onboard = Setup.step_id(:onboard)
    children = for %{id: id, parent: ^onboard} <- Setup.steps(), do: id

    assert children != []

    for id <- children do
      assert doc =~ id, "the skill never names sub-step #{id}"
    end
  end

  # Scenario 3
  test "names every interview question id", %{doc: doc} do
    ids = Enum.map(Setup.interview_questions(), & &1.id)
    assert ids != []

    for id <- ids do
      assert doc =~ "`#{id}`", "the skill never names interview question #{id}"
    end
  end

  # Scenario 4
  test "refuses a board with no checklist politely", %{doc: doc} do
    assert doc =~ "This board predates guided setup; use /relay-doctor."
  end

  # Scenario 5
  test "the retired paths and the vendor name are gone", %{doc: doc} do
    refute doc =~ ~r/\b(seed|adopt|adopting|hybrid)\b/i
    refute doc =~ "Claude"
  end

  # Scenario 6
  test "drives the loop through ./relay setup and names its artifacts", %{doc: doc} do
    for needle <- [
          "./relay setup status",
          "./relay setup report",
          "not_current",
          ".relay/project.md",
          "In a new terminal, run ./relay start",
          "--tag setup",
          ~s("enabled": true),
          "your LLM"
        ] do
      assert doc =~ needle, "the skill does not say #{inspect(needle)}"
    end
  end

  # Scenario 7
  test "forbids flow nodes, names its blast radius, and never touches app code", %{doc: doc} do
    assert doc =~ "Never run this from a flow node"
    assert doc =~ "**Blast radius:**"
    assert doc =~ "app code"
  end

  # Scenario 8
  test "bounds retries at 3 and offers the three stuck options", %{doc: doc} do
    assert doc =~ "attempt 3/3"
    assert doc =~ ~s({"attempts": 3})

    for option <- ["show the diff", "reset and redo", "#setup card"] do
      assert doc =~ option
    end
  end

  # Scenario 9
  test "mentions each data key and change decision the wizard renders", %{doc: doc} do
    for key <- ["answers", "changes", "pr_url", "attempts"] do
      assert doc =~ ~s("#{key}"), "the skill never reports data key #{key}"
    end

    for decision <- Setup.change_decisions() -- ["pending"] do
      assert doc =~ "`#{decision}`", "the skill never names decision #{decision}"
    end
  end

  # A `## <heading>` section of the skill, up to the next `## ` heading.
  defp section(doc, heading) do
    [_before, rest] = String.split(doc, "\n" <> heading, parts: 2)
    rest |> String.split("\n## ", parts: 2) |> hd()
  end

  # RE447 task 3, scenario 6
  test "names every missing-file resolution, the 5.4 progress evidence and referenced_files", %{doc: doc} do
    for resolution <- Setup.missing_file_resolutions() do
      assert doc =~ "`#{resolution}`", "the skill never names resolution #{resolution}"
    end

    assert doc =~ "missing files k of N resolved"
    assert doc =~ "`referenced_files`"
  end

  # RE447 task 3, scenario 7
  test "5.4 walks the missing files before listing the proposals, re-asking on a bad path", %{doc: doc} do
    customize = section(doc, "## 5.4")
    {missing_at, _} = :binary.match(customize, "missing_files")
    {proposals_at, _} = :binary.match(customize, "list **every** proposed change")

    assert missing_at < proposals_at
    assert customize =~ "Copied it from there."
    assert customize =~ "doesn't exist"
  end

  # RE447 task 3, scenario 8
  test "5.1 lists the missing files and stays silent when nothing is missing", %{doc: doc} do
    pull = section(doc, "## 5.1")

    assert pull =~ "missing_files"
    assert pull =~ "referenced_files"
    assert pull =~ "nothing is missing"
  end

  # Scenario 10
  test "no flow in this repo names relay-onboard as a node step" do
    files = Path.wildcard(".relay/flows/*.json") ++ Path.wildcard("docs/designs/flows/*.json")
    assert files != []

    for file <- files, node <- file |> File.read!() |> Jason.decode!() |> Map.get("nodes", []) do
      refute Jason.encode!(node) =~ "relay-onboard",
             "#{file} node #{node["key"]} names relay-onboard as a step"
    end
  end

  describe "discoverability" do
    test "relay.md's Setup section names the skill" do
      assert File.read!("relay.md") =~ "/relay-onboard"
    end

    test "AGENTS.md names it under Skill discipline, without the retired paths" do
      agents = File.read!("AGENTS.md")
      assert agents =~ "/relay-onboard"
      refute agents =~ ~r/seed \/ adopt \/ hybrid/
    end
  end
end
