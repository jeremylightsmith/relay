defmodule Relay.DocsTasksContractTest do
  @moduledoc """
  RE367: the factory, relay.md and the flow docs speak the canonical flow-contract names
  (`tasks`, `card.tasks`, `{task}`, `{task_id}`). A `sub_task` / `sub-task` mention survives only
  on a line that documents the legacy alias (it says "legacy").
  """
  use ExUnit.Case, async: true

  @swept ["relay.md"] ++
           Path.wildcard(".claude/commands/*.md") ++
           Path.wildcard(".claude/agents/**/*.md") ++
           Path.wildcard(".claude/skills/relay-*/**/*.md") ++
           Path.wildcard("docs/designs/flows/*.{json,md,dot}")

  test "no stale sub_task contract name outside a legacy note" do
    stale =
      for path <- @swept,
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/sub[_-]task/i,
          not (line =~ ~r/legacy/i),
          not (line =~ "sub_task_id\": "),
          do: "#{path}:#{n}: #{line}"

    assert stale == []
  end

  test "the glossary defines Task and names its legacy identifiers" do
    glossary = File.read!("docs/glossary.md")

    assert glossary =~ "- **Task** —"
    assert glossary =~ "relay task show"
    assert glossary =~ "`sub_task` / `SubTask` / `sub_tasks`"
  end
end
