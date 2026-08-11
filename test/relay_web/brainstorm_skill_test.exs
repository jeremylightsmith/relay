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
    assert doc =~ "needs-input"
  end

  test "defers the questions payload shape to the injected outcome contract", %{doc: doc} do
    # The shape is appended to every agent prompt by bin/relay's OUTCOME_CONTRACT. This skill
    # keeps the judgement it uniquely owns — how to write a good question — and stops carrying
    # a second copy of the schema that can drift from the validator.
    assert doc =~ "outcome contract"
    refute doc =~ "allow_text\":"
    refute doc =~ "<<'JSON'"
  end

  test "points onward to /write-plan", %{doc: doc} do
    assert doc =~ "/write-plan"
  end

  test "no longer writes a docs/superpowers/specs file", %{doc: doc} do
    refute doc =~ "docs/superpowers/specs"
  end

  test "writes the card's acceptance criteria via relay criteria", %{doc: doc} do
    assert doc =~ "bin/relay criteria"
  end

  test "specifies the numbered-criterion / numbered-steps / one-expectation format", %{doc: doc} do
    assert doc =~ "one observable expectation"
    assert doc =~ "Expect:"
  end

  test "authors criteria even when the card has no runtime surface", %{doc: doc} do
    assert doc =~ "no runtime surface"
  end
end
