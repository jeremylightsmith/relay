defmodule Relay.DesignSkillsTest do
  use ExUnit.Case, async: true

  # The Design stage hands HTML mockups downstream on the card itself. These pin the
  # contract between the skills that write them and the agents that read them: a mockup is
  # matched only when the spec names it as `Match card mockup "<caption>"`.
  @root File.cwd!()
  @design Path.join([@root, ".claude", "skills", "design", "SKILL.md"])
  @brainstorm Path.join([@root, ".claude", "skills", "brainstorm", "SKILL.md"])

  describe "the design skill" do
    setup do
      {:ok, doc: File.read!(@design)}
    end

    test "is triggered by the Design stage, not a summary of its workflow", %{doc: doc} do
      assert doc =~ ~r/^description: Use when /m
      assert doc =~ "Design:Review"
    end

    test "never writes the repo: mockups are pulled into the node scratch dir", %{doc: doc} do
      assert doc =~ ~S|S="$(dirname "$RELAY_NODE_SCRATCH")"|
      assert doc =~ ~S|./relay mockups <ref> --pull "$S/prev"|
    end

    test "builds CSS with the tailwind version config.exs pins, not the last binary listed", %{doc: doc} do
      assert doc =~ "config/config.exs"
      refute doc =~ "tail -1"
    end

    test "requests no web font, because Relay's own type is system fonts", %{doc: doc} do
      refute doc =~ "fonts.googleapis.com/css2"
    end

    test "replaces the ## Design section in place", %{doc: doc} do
      assert doc =~ "./relay describe <ref>"
      assert doc =~ ~S|^#{1,2} |
    end
  end

  describe "brainstorm" do
    setup do
      {:ok, doc: File.read!(@brainstorm)}
    end

    test "names card mockups in the spec with the phrase downstream keys off", %{doc: doc} do
      assert doc =~ ~S|Match card mockup "<caption>"|
    end

    test "splits by creating slices in Backlog and moving them to Spec:Review last", %{doc: doc} do
      assert doc =~ "## Splitting a card that's too big"
      assert doc =~ "--stage Backlog"
      assert doc =~ ~S|./relay move "$ref" "Spec:Review"|
      refute doc =~ ~S|--stage "Spec:Review"|
    end
  end

  describe "downstream readers resolve a named card mockup" do
    for path <- [
          ~w(.claude commands write-plan.md),
          ~w(.claude agents plan-implementer.md),
          ~w(.claude agents quality-reviewer.md),
          ~w(.claude agents final-reviewer.md),
          ~w(.claude agents smoke-tester.md)
        ] do
      test "#{List.last(path)} knows a card mockup and how to pull it" do
        doc = File.read!(Path.join([@root | unquote(path)]))
        assert doc =~ "card mockup"
        assert doc =~ ~r/\.\/relay mockups <ref>\s+--pull/
      end
    end
  end
end
