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

  test "a plan with no task headings yields []" do
    assert PlanTasks.parse("# Just prose\n\nNothing to do here.") == []
  end

  test "nil and blank plans yield []" do
    assert PlanTasks.parse(nil) == []
    assert PlanTasks.parse("") == []
  end
end
