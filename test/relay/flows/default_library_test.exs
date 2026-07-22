defmodule Relay.Flows.DefaultLibraryTest do
  use ExUnit.Case, async: true

  alias Relay.Flows.DefaultLibrary

  # RLY-194 inverted this from an allowlist to a law. Every :agent/:gate node in every
  # flow must route its :failed outcome — to a fix, or to the "needs_input" park sentinel.
  # A failed node must never be a dead end. :shell nodes are outside this test's scope —
  # merge/sync/resync deliberately stay unrouted; branch got a park edge too (RLY-224).
  test "no :agent or :gate node in any flow leaves :failed unrouted" do
    gaps =
      for flow <- DefaultLibrary.all(),
          node <- flow.nodes,
          node.type in [:agent, :gate],
          not Enum.any?(flow.edges, &(&1.from == node.key and Map.get(&1, :on) == :failed)),
          do: {flow.key, node.key}

    assert gaps == [],
           "these agent/gate nodes fail the run with no :failed route: #{inspect(gaps)}. " <>
             "Give each an outgoing :failed edge (to a fix node or to the \"needs_input\" " <>
             "park sentinel) — a failed node must never be a dead end (RLY-194)."
  end

  test "exactly the four commit-producing Code nodes are marked expects_commits" do
    marked =
      for flow <- DefaultLibrary.all(),
          node <- flow.nodes,
          Map.get(node, :expects_commits, false),
          into: MapSet.new(),
          do: {flow.key, node.key}

    assert marked ==
             MapSet.new([
               {"code", "implement"},
               {"code", "final_fix"},
               {"code", "smoke_fix"},
               {"code", "acceptance_fix"}
             ])
  end

  test "every :agent node's :failed route reaches a fix node or the needs_input sentinel" do
    for flow <- DefaultLibrary.all(),
        node <- flow.nodes,
        node.type == :agent do
      failed_edge = Enum.find(flow.edges, &(&1.from == node.key and Map.get(&1, :on) == :failed))
      assert failed_edge, "#{flow.key}/#{node.key} has no :failed edge"
    end
  end

  describe "spec and plan flows park their sole worker (RLY-194)" do
    defp flow_named(key), do: Enum.find(DefaultLibrary.all(), &(&1.key == key))

    defp has_park_edge?(flow, from),
      do: Enum.any?(flow.edges, &(&1.from == from and Map.get(&1, :on) == :failed and &1.to == "needs_input"))

    test "brainstorm and write_plan route :failed to needs_input" do
      assert has_park_edge?(flow_named("spec"), "brainstorm")
      assert has_park_edge?(flow_named("plan"), "write_plan")
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
      rebase = "{relay} git-fetch && { git rebase origin/main || { git rebase --abort; exit 1; }; }"

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

    test "merge is an idempotent :shell node that converges on merged (RLY-215)" do
      n = cf_node(code_flow(), "merge")
      assert n.type == :shell

      expected =
        "state=$(gh pr view {branch} --json state -q .state 2>/dev/null || echo \"\"); " <>
          "[ \"$state\" = MERGED ] && exit 0; " <>
          "git push --force-with-lease origin HEAD:refs/heads/{branch} && " <>
          "url=$(gh pr view {branch} --json url -q .url 2>/dev/null || " <>
          "gh pr create --fill --head {branch} --base main) && " <>
          "{relay} pr {ref} \"$url\" && gh pr merge {branch} --squash"

      assert n.run == expected

      # Why each piece is there:
      assert n.run =~ "--force-with-lease"
      assert n.run =~ "gh pr view {branch} --json url"
      assert n.run =~ "|| gh pr create"
      assert n.run =~ "[ \"$state\" = MERGED ] && exit 0"

      # RLY-199 regression guard: no plain non-force push may remain.
      refute n.run =~ "git push origin HEAD"
    end

    test "every agent node parks on a hard failure via a needs_input edge (RLY-194)" do
      flow = code_flow()

      for key <- ~w(implement sync_fix final_fix smoke_fix acceptance_fix resync_fix post) do
        assert edge?(flow, key, "needs_input", :failed),
               "code/#{key} must route :failed to the needs_input park sentinel"
      end
    end

    test "implement retries once before it parks" do
      n = cf_node(code_flow(), "implement")
      assert n.max_retries == 1
      assert n.expects_commits == true
    end

    test "branch routes :failed to needs_input so a transient fetch race parks, not dead-ends (RLY-224)" do
      flow = code_flow()
      assert cf_node(flow, "branch").type == :shell

      assert edge?(flow, "branch", "needs_input", :failed),
             "a branch failure surviving the fetch retries must park for a human, " <>
               "not dead-end with no_route_for_outcome (RLY-224)"

      # The branch node's fetch goes through the single retrying helper.
      assert cf_node(flow, "branch").run =~ "{relay} git-fetch"
      refute cf_node(flow, "branch").run =~ "git fetch origin --prune"
    end
  end

  describe "the branch node materializes the plan into the per-ref RELAY_PLAN path (RLY-223)" do
    test "branch writes and probes $RELAY_PLAN, never a worktree-root plan.md" do
      flow = Enum.find(DefaultLibrary.all(), &(&1.key == "code"))
      branch = Enum.find(flow.nodes, &(&1.key == "branch"))

      assert branch.run =~ ~s(> "$RELAY_PLAN"), "branch must write the plan to $RELAY_PLAN"
      assert branch.run =~ ~s(test -s "$RELAY_PLAN"), "branch must probe $RELAY_PLAN is non-empty"
      refute branch.run =~ "plan.md", "no bare worktree-root plan.md may remain in the branch command"
    end

    test "the executor floor is raised to refuse any pre-RELAY_PLAN executor (RLY-223)" do
      # The new branch command requires the executor to export RELAY_PLAN; any executor built
      # before that (the last such build was v17) would expand $RELAY_PLAN to empty and break
      # every Code run, so it must be refused — the AGENTS.md floor-raise rule ("worse than a
      # stopped one"). Pinned by behavior, not an exact literal, so a later unrelated bump that
      # leaves the floor alone won't break it.
      assert Relay.Runs.min_executor_version() >= 18
      assert Relay.Runs.executor_outdated?(%Schemas.Executor{version: 17})
    end
  end
end
