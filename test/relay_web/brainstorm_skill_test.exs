defmodule Relay.BrainstormSkillTest do
  use ExUnit.Case, async: true

  @skill Path.join([File.cwd!(), ".claude", "skills", "brainstorm", "SKILL.md"])

  setup do
    {:ok, doc: File.read!(@skill)}
  end

  test "takes an optional card ref from $ARGUMENTS", %{doc: doc} do
    assert doc =~ "$ARGUMENTS"
  end

  test "writes the approved spec to the card via relay spec", %{doc: doc} do
    assert doc =~ "bin/relay spec"
  end

  test "creates a new card when no ref is given", %{doc: doc} do
    assert doc =~ "bin/relay create"
  end

  test "asks the human via needs-input in headless/runner use", %{doc: doc} do
    assert doc =~ "bin/relay needs-input"
  end

  test "points onward to /write-plan", %{doc: doc} do
    assert doc =~ "/write-plan"
  end

  test "no longer writes a docs/superpowers/specs file", %{doc: doc} do
    refute doc =~ "docs/superpowers/specs"
  end
end
