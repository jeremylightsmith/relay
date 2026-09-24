defmodule Relay.Flows.DefaultLibraryTest do
  use ExUnit.Case, async: true

  alias Relay.Flows.DefaultLibrary

  test "the library is loaded from docs/designs/flows/*.json, and pins them as external resources" do
    assert length(DefaultLibrary.all()) == 3
    assert Enum.map(DefaultLibrary.all(), & &1.key) == ["spec", "plan", "code"]

    code = Enum.find(DefaultLibrary.all(), &(&1.key == "code"))
    assert length(code.nodes) == 21
    assert length(code.edges) == 44
    assert code.isolation == :exclusive
    assert code.trigger == %{pulls_from: "Plan:Done", works_in: "Code", lands_on: "Review"}

    # `@external_resource` is accumulated, so it appears three times in the attribute list —
    # Keyword.get_values/2, not `kw[:external_resource]`, which would return only the first.
    resources =
      :attributes
      |> DefaultLibrary.__info__()
      |> Keyword.get_values(:external_resource)
      |> List.flatten()

    assert length(resources) == 3
    assert Enum.any?(resources, &String.ends_with?(to_string(&1), "docs/designs/flows/code.json"))
  end

  test "decode is dense, so every node carries every field (the customized?/1 comparison depends on it)" do
    for flow <- DefaultLibrary.all(), node <- flow.nodes do
      assert Enum.sort(Map.keys(node)) == Enum.sort(Schemas.Flow.Node.fields())
    end
  end

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

  test "exactly the three commit-producing Code nodes are marked expects_commits" do
    marked =
      for flow <- DefaultLibrary.all(),
          node <- flow.nodes,
          Map.get(node, :expects_commits, false),
          into: MapSet.new(),
          do: {flow.key, node.key}

    assert marked ==
             MapSet.new([
               {"code", "implement"},
               {"code", "fix_findings"},
               {"code", "final_fix"}
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

    # CI runs the Playwright journeys as their own job, so a flow that only gates on
    # `mix precommit` finds a red browser suite after the merge. Both precommit gates are
    # followed by a browser gate, and both fixers they feed are told to keep it green.
    test "browser / rebrowser gate the branch on mix test.browser after each precommit gate" do
      flow = code_flow()

      for key <- ~w(browser rebrowser) do
        n = cf_node(flow, key)
        assert n.type == :gate
        assert n.run == "mix test.browser"
      end

      assert edge?(flow, "precommit", "browser", :succeeded)
      assert edge?(flow, "browser", "final_review", :succeeded)
      assert edge?(flow, "browser", "final_fix", :failed)
      assert edge?(flow, "reverify", "rebrowser", :succeeded)
      assert edge?(flow, "rebrowser", "merge", :succeeded)
      assert edge?(flow, "rebrowser", "resync_fix", :failed)

      assert cf_node(flow, "final_fix").run =~ "mix test.browser"
      assert cf_node(flow, "resync_fix").run =~ "mix test.browser"
    end

    test "sync point A replaces quality_review → precommit" do
      flow = code_flow()
      refute edge?(flow, "quality_review", "precommit", :succeeded, :foreach_exhausted)
      assert edge?(flow, "quality_review", "sync", :succeeded, :foreach_exhausted)
      assert edge?(flow, "sync", "precommit", :succeeded)
      assert edge?(flow, "sync", "sync_fix", :failed)
      assert edge?(flow, "sync_fix", "precommit", :succeeded)
    end

    test "sync point B sits between acceptance and merge, gated by reverify, and merge can retry" do
      flow = code_flow()
      assert edge?(flow, "acceptance", "resync", :succeeded)
      assert edge?(flow, "resync", "reverify", :succeeded)
      assert edge?(flow, "resync", "resync_fix", :failed)
      assert edge?(flow, "resync_fix", "reverify", :succeeded)
      assert edge?(flow, "reverify", "resync_fix", :failed)
      assert edge?(flow, "merge", "resync", :failed)
    end

    # A card reaches Review only once its change is live: `deploy` waits for the PR to merge and
    # main's CI to deploy it, and `post` runs last so the summary describes what actually shipped.
    test "merge → deploy → post → done, and a failed deploy re-lands through github_fix" do
      flow = code_flow()
      assert edge?(flow, "merge", "deploy", :succeeded)
      assert edge?(flow, "deploy", "post", :succeeded)
      assert edge?(flow, "post", "done", :succeeded)
      refute edge?(flow, "merge", "done", :succeeded)

      deploy = cf_node(flow, "deploy")
      assert deploy.type == :shell
      assert deploy.run =~ "bin/await_deploy.sh"

      github_fix = cf_node(flow, "github_fix")
      assert github_fix.type == :agent
      assert github_fix.agent == "ci-fixer"
      assert edge?(flow, "deploy", "github_fix", :failed)
      assert edge?(flow, "github_fix", "resync", :succeeded)
    end

    test "merge is an idempotent :shell node that converges on merged (RLY-215)" do
      n = cf_node(code_flow(), "merge")
      assert n.type == :shell

      expected =
        ~S<sha=$(git rev-parse HEAD); > <>
          ~S<url=$(gh pr list --head {branch} --state merged --json url,headRefOid > <>
          ~S<-q "map(select(.headRefOid == \"$sha\"))[0].url // empty"); > <>
          ~S<if [ -n "$url" ]; then {relay} pr {ref} "$url"; exit 0; fi; > <>
          ~S<if [ "$(git rev-list --count origin/main..HEAD)" = 0 ]; then > <>
          ~S<echo 'nothing on {branch} beyond origin/main to ship'; exit 0; fi; > <>
          ~S<git push --force-with-lease origin HEAD:refs/heads/{branch} && > <>
          ~S<url=$(gh pr list --head {branch} --state open --json url -q '.[0].url // empty') && > <>
          ~S<{ [ -n "$url" ] || url=$(gh pr create --fill --head {branch} --base main); } && > <>
          ~S<{relay} pr {ref} "$url" && gh pr merge "$url" --squash --auto>

      assert n.run == expected

      # Why each piece is there:
      assert n.run =~ "--force-with-lease"
      assert n.run =~ "|| url=$(gh pr create"

      # TH-116: "a PR on this branch merged" is not "this work merged". A card rejected in Review
      # after its first PR merged comes back with new commits on the same branch; a state-only
      # MERGED check exited 0 and those commits never reached origin. Only a merged PR whose head
      # IS this HEAD short-circuits, and the open-PR lookup ignores the old merged one.
      assert n.run =~ ~S<.headRefOid == \"$sha\">
      assert n.run =~ "--state open"

      # RE254 / TH13: a bare `gh pr merge --squash` demands an immediate merge and dies on a repo
      # whose branch policy still has checks IN_PROGRESS. `--auto` queues the squash-merge until
      # the required checks pass; `deploy` then waits for it to land.
      assert n.run =~ ~S<gh pr merge "$url" --squash --auto>

      # RLY-199 regression guard: no plain non-force push may remain.
      refute n.run =~ "git push origin HEAD"
    end

    test "every agent node parks on a hard failure via a needs_input edge (RLY-194)" do
      flow = code_flow()

      for key <- ~w(implement fix_findings sync_fix final_fix resync_fix github_fix post) do
        assert edge?(flow, key, "needs_input", :failed),
               "code/#{key} must route :failed to the needs_input park sentinel"
      end
    end

    # A rejected per-task review goes to a fixer that only addresses the findings — not back to
    # the implementer, which re-derived the task from the plan, decided it was already done and
    # reported success with nothing changed.
    test "per-task review failures route to fix_findings, which returns to spec_review" do
      flow = code_flow()

      for from <- ~w(spec_review quality_review) do
        assert edge?(flow, from, "fix_findings", :failed)
        refute edge?(flow, from, "implement", :failed)
      end

      assert edge?(flow, "fix_findings", "spec_review", :succeeded)
      n = cf_node(flow, "fix_findings")
      assert n.agent == "final-fixer"
      assert n.expects_commits == true
    end

    test "smoke and acceptance failures share the one final_fix fixer" do
      flow = code_flow()
      assert edge?(flow, "smoke", "final_fix", :failed)
      assert edge?(flow, "acceptance", "final_fix", :failed)
      refute cf_node(flow, "smoke_fix")
      refute cf_node(flow, "acceptance_fix")
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

      # A card sent back while its PR is still open resumes from that branch rather than
      # resetting its unmerged commits away onto origin/main.
      assert cf_node(flow, "branch").run =~ "gh pr list --head {branch} --state open"
      assert cf_node(flow, "branch").run =~ "base=origin/{branch}"

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

    test "the runner floor is raised to refuse any pre-RELAY_PLAN runner (RLY-223)" do
      # The new branch command requires the runner to export RELAY_PLAN; any runner built
      # before that (the last such build was v17) would expand $RELAY_PLAN to empty and break
      # every Code run, so it must be refused — the AGENTS.md floor-raise rule ("worse than a
      # stopped one"). Pinned by behavior, not an exact literal, so a later unrelated bump that
      # leaves the floor alone won't break it.
      assert Relay.Runs.min_runner_version() >= 18
      assert Relay.Runs.runner_outdated?(%Schemas.Runner{version: 17})
    end
  end

  test "the shipped flows declare exactly the RE244 card contract" do
    declared =
      for flow <- DefaultLibrary.all(),
          node <- flow.nodes,
          node.reads != [] or node.writes != [],
          into: %{},
          do: {{flow.key, node.key}, {node.reads, node.writes}}

    assert declared == %{
             {"spec", "brainstorm"} => {[:description], [:spec, :acceptance_criteria]},
             {"plan", "write_plan"} => {[:spec, :acceptance_criteria], [:plan]},
             {"code", "branch"} => {[:plan], [:branch]},
             {"code", "post"} => {[], [:ai_result]},
             {"code", "merge"} => {[], [:pr_url]}
           }
  end

  # RLY-165: sub_tasks are seeded server-side at Code-run start from card.plan, so no node
  # may claim to write them — a declared write is ENFORCED and would fail write_plan.
  test "no shipped node declares it writes sub_tasks" do
    for flow <- DefaultLibrary.all(), node <- flow.nodes do
      refute :sub_tasks in node.writes, "#{flow.key}/#{node.key} must not declare sub_tasks"
    end
  end

  test "the branch node records the branch on the card, last in the chain (RE244 §5)" do
    flow = Enum.find(DefaultLibrary.all(), &(&1.key == "code"))
    branch = Enum.find(flow.nodes, &(&1.key == "branch"))

    # Last deliberately: if the plan is missing, the node fails and no branch is recorded.
    assert String.ends_with?(branch.run, "&& {relay} branch {ref} {branch}")
  end

  # The node declares `writes: [pr_url]` and the guard demotes a `succeeded` that left it
  # blank. `merge` has no `failed -> needs_input` edge, so a blank write bounces
  # merge -> resync -> reverify -> merge until the loop budget is spent and the run fails
  # terminally. The already-MERGED fast path must therefore record the URL too: a PR merged
  # out of band (`/finish`, or a human merging in the GitHub UI while the run is parked)
  # leaves `pr_url` blank, and this node's happy path is the ONLY writer of that field.
  test "the merge node records pr_url on its already-MERGED fast path too (RE244 §5)" do
    flow = Enum.find(DefaultLibrary.all(), &(&1.key == "code"))
    merge = Enum.find(flow.nodes, &(&1.key == "merge"))

    assert :pr_url in merge.writes

    [fast_path, _rest] = String.split(merge.run, "fi;", parts: 2)

    assert fast_path =~ "{relay} pr {ref} \"$url\"",
           "the MERGED branch must record pr_url before it exits, or the guard fails the run"

    assert fast_path =~ "exit 0",
           "the MERGED branch must still short-circuit rather than re-push and re-merge"
  end

  test "the post node records the structured ai_result, not just a comment (RE244 §5)" do
    flow = Enum.find(DefaultLibrary.all(), &(&1.key == "code"))
    post = Enum.find(flow.nodes, &(&1.key == "post"))

    assert post.run =~ "{relay} result {ref}"
    # `./relay result` does json.loads(text) — the argument must be a JSON object, not prose.
    assert post.run =~ "JSON object"
  end

  test "the post node spells out the house style for `summary` and `changes`" do
    flow = Enum.find(DefaultLibrary.all(), &(&1.key == "code"))
    post = Enum.find(flow.nodes, &(&1.key == "post"))

    # The drawer renders `summary` as markdown and `changes` as a checked list, and the reader is
    # a product owner deciding what to review — so the shape is an editorial contract, not taste.
    # Dropping it turns the summary back into a "the task is complete" restatement of the comment.
    assert post.run =~ "3-5 bullets"
    assert post.run =~ "product owner"
    assert post.run =~ "verb phrases"
  end

  # RE327 — the deployment link is gone from the drawer, and `Relay.Cards` refuses any key
  # outside `ai_result_keys/0` with 422 invalid_ai_result. The prompt names exactly those keys and
  # the two a screen may carry, and says outright that `deploy_url` is not one of them.
  test "the post node asks only for the result keys the server accepts" do
    flow = Enum.find(DefaultLibrary.all(), &(&1.key == "code"))
    post = Enum.find(flow.nodes, &(&1.key == "post"))

    for key <- Relay.Cards.ai_result_keys() ++ Relay.Cards.ai_result_screen_keys() do
      assert post.run =~ "`#{key}`"
    end

    assert post.run =~ "there is no `deploy_url`"
    assert post.run =~ "{relay} attach {ref}"
  end
end
