defmodule Relay.Flows.DefaultLibraryTest do
  use ExUnit.Case, async: true

  alias Relay.Flows.DefaultLibrary

  # RLY-157 died on `no_route_for_outcome: final_fix → failed` — a node with no
  # outgoing :failed edge at all, which the RLY-179 degrade cannot rescue. For each
  # node below, failing the run IS the intended behavior; the defect was that it was
  # never stated. This allowlist is where that decision lives. Adding a node here is
  # a deliberate act: you are declaring "when this node fails, the run is over."
  @intentional_termini %{
    {"spec", "brainstorm"} =>
      "The only node in the flow. A brainstorm that cannot produce a spec has nothing to hand on.",
    {"plan", "write_plan"} => "The only node in the flow. A planner that cannot plan has nothing to hand on.",
    {"code", "implement"} =>
      "An implementer that cannot implement the task has nothing left to try; retries are spent by then.",
    {"code", "final_fix"} => "A fixer that cannot fix the review's findings has nothing left to try.",
    {"code", "smoke_fix"} => "A fixer that cannot fix what the smoke run proved broken has nothing left to try.",
    {"code", "acceptance_fix"} => "A fixer that cannot fix the failing criteria has nothing left to try.",
    {"code", "post"} =>
      "Posting the checklist is the last step before merge; a failure there needs a human, not another node."
  }

  test "every agent/gate node either has an outgoing :failed edge or is a documented terminus" do
    gaps =
      for flow <- DefaultLibrary.all(),
          node <- flow.nodes,
          node.type in [:agent, :gate],
          not Enum.any?(flow.edges, &(&1.from == node.key and Map.get(&1, :on) == :failed)),
          not Map.has_key?(@intentional_termini, {flow.key, node.key}),
          do: {flow.key, node.key}

    assert gaps == [],
           "these agent/gate nodes fail the run with no stated reason: #{inspect(gaps)}. " <>
             "Either give them an outgoing :failed edge, or add them to @intentional_termini " <>
             "with the reason failing is correct."
  end

  test "the allowlist has no stale entries" do
    real_nodes =
      for flow <- DefaultLibrary.all(), node <- flow.nodes, into: MapSet.new(), do: {flow.key, node.key}

    stale = for key <- Map.keys(@intentional_termini), not MapSet.member?(real_nodes, key), do: key
    assert stale == [], "@intentional_termini names nodes that no longer exist: #{inspect(stale)}"
  end

  test "every allowlisted terminus states a reason" do
    for {key, reason} <- @intentional_termini do
      assert is_binary(reason) and String.trim(reason) != "", "no reason given for #{inspect(key)}"
    end
  end
end
