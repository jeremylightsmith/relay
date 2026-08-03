defmodule Relay.DocsStoryMapTest do
  @moduledoc """
  RE265: the story map adds a context, three schemas, three card columns and a PubSub event —
  all four are `docs/architecture/` gates, and "Activity" now means two different things in
  this repo (the card activity log and a story-map column), so the glossary must disambiguate.
  A doc convention with no test is a doc convention that drifts back within a month.
  """
  use ExUnit.Case, async: true

  defp read(path), do: File.read!(Path.join(File.cwd!(), path))

  test "domain.md documents the StoryMap context, its schemas and the card columns" do
    domain = read("docs/architecture/domain.md")

    assert domain =~ "**StoryMap**"
    assert domain =~ "Relay.StoryMap"

    for schema <- ["StoryActivity", "StoryTask", "Release"] do
      assert domain =~ schema, "domain.md should name the #{schema} schema"
    end

    for column <- ["story_activity_id", "story_task_id", "release_id"] do
      assert domain =~ column, "domain.md should name the #{column} card column"
    end
  end

  test "runtime.md lists the new board event" do
    assert read("docs/architecture/runtime.md") =~ "{:story_map_changed, board_id}"
  end

  test "the glossary disambiguates story-map Activity from the card activity log" do
    glossary = read("docs/glossary.md")

    assert glossary =~ "Activity (story map)"
    assert glossary =~ "Task (story map)"
    assert glossary =~ "Release"
    assert glossary =~ "Schemas.StoryActivity"
    assert glossary =~ "Schemas.StoryTask"
    assert glossary =~ "Schemas.Release"
  end
end
