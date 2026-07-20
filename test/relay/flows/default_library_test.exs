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
      "Posting the checklist is the last step before merge; a failure there needs a human, not another node.",
    {"code", "sync_fix"} =>
      "A rebaser that can neither resolve the conflict nor get a human answer (it parks via needs-input) has nothing left to try.",
    {"code", "resync_fix"} =>
      "Same as sync_fix: the pre-merge rebaser parks via needs-input; a hard failure there ends the run for a human."
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

  describe "code flow sync points (RLY-192)" do
    defp code_flow, do: Enum.find(DefaultLibrary.all(), &(&1.key == "code"))
    defp cf_node(flow, key), do: Enum.find(flow.nodes, &(&1.key == key))

    defp edge?(flow, from, to, on, guard \\ nil) do
      Enum.any?(flow.edges, fn e ->
        e.from == from and e.to == to and Map.get(e, :on) == on and Map.get(e, :when) == guard
      end)
    end

    test "sync / resync are identical cheap :shell rebases that abort before handing over" do
      flow = code_flow()
      rebase = "git fetch origin --prune && { git rebase origin/main || { git rebase --abort; exit 1; }; }"

      for key <- ~w(sync resync) do
        n = cf_node(flow, key)
        assert n.type == :shell
        assert n.run == rebase
      end
    end

    test "sync_fix / resync_fix are :agent nodes running the rebaser on sonnet" do
      flow = code_flow()

      for key <- ~w(sync_fix resync_fix) do
        n = cf_node(flow, key)
        assert n.type == :agent
        assert n.agent == "rebaser"
        assert n.model == "sonnet"
      end
    end

    test "reverify is a :gate running mix precommit" do
      n = cf_node(code_flow(), "reverify")
      assert n.type == :gate
      assert n.run == "mix precommit"
    end

    test "sync point A replaces quality_review → precommit" do
      flow = code_flow()
      refute edge?(flow, "quality_review", "precommit", :succeeded, :foreach_exhausted)
      assert edge?(flow, "quality_review", "sync", :succeeded, :foreach_exhausted)
      assert edge?(flow, "sync", "precommit", :succeeded)
      assert edge?(flow, "sync", "sync_fix", :failed)
      assert edge?(flow, "sync_fix", "precommit", :succeeded)
    end

    test "sync point B sits between post and merge, gated by reverify, and merge can retry" do
      flow = code_flow()
      refute edge?(flow, "post", "merge", :succeeded)
      assert edge?(flow, "post", "resync", :succeeded)
      assert edge?(flow, "resync", "reverify", :succeeded)
      assert edge?(flow, "resync", "resync_fix", :failed)
      assert edge?(flow, "resync_fix", "reverify", :succeeded)
      assert edge?(flow, "reverify", "resync_fix", :failed)
      assert edge?(flow, "reverify", "merge", :succeeded)
      assert edge?(flow, "merge", "done", :succeeded)
      assert edge?(flow, "merge", "resync", :failed)
    end
  end
end
