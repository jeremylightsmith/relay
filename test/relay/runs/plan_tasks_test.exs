defmodule Relay.Runs.PlanTasksTest do
  use ExUnit.Case, async: true

  alias Relay.Runs.PlanTasks

  test "extracts `### Task N: <name>` headings in document order" do
    plan = """
    # A plan

    Some preamble mentioning ### Task 0: not a heading inline.

    ### Task 1: Schema and migration

    - [ ] do the thing

    ### Task 2: Wire it up

    ### Task 10: The last one
    """

    assert PlanTasks.parse(plan) == [
             %{title: "Schema and migration"},
             %{title: "Wire it up"},
             %{title: "The last one"}
           ]
  end

  test "accepts ## through #### — the heading level is prose, not a contract" do
    # RLY-165: the parser demanded exactly ###, but /write-plan emits ## about as often.
    # The real Code dogfood on RLY-159 parsed to [] for this reason alone, and the run then
    # skipped every implement lap. The task list must not hinge on a hash count.
    plan = """
    ## Task 1: Two hashes

    ### Task 2: Three hashes

    #### Task 3: Four hashes
    """

    assert PlanTasks.parse(plan) == [
             %{title: "Two hashes"},
             %{title: "Three hashes"},
             %{title: "Four hashes"}
           ]
  end

  test "accepts colon, em-dash, en-dash, or hyphen as the Task-number separator" do
    # RLY-206/RLY-209: /write-plan repeatedly emitted `## Task N — <name>` (em-dash); the
    # parser demanded a colon, silently yielded [], and the card parked in needs_input with
    # "plan produced no tasks". Punctuation after the number is prose, not a contract.
    plan = """
    ## Task 1: Colon
    ## Task 2 — Em-dash
    ## Task 3 – En-dash
    ## Task 4 - Hyphen
    """

    assert PlanTasks.parse(plan) == [
             %{title: "Colon"},
             %{title: "Em-dash"},
             %{title: "En-dash"},
             %{title: "Hyphen"}
           ]
  end

  test "a single hash is a document title, not a task" do
    assert PlanTasks.parse("# Task 1: this is the plan's own title") == []
  end

  test "a plan with no task headings yields []" do
    assert PlanTasks.parse("# Just prose\n\nNothing to do here.") == []
  end

  test "nil and blank plans yield []" do
    assert PlanTasks.parse(nil) == []
    assert PlanTasks.parse("") == []
  end
end
