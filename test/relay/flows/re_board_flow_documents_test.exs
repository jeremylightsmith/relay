defmodule Relay.Flows.ReBoardFlowDocumentsTest do
  @moduledoc """
  RE408. The RE board's checked-in flow documents (`.relay/flows/code.json`, `.relay/flows/deploy.json`)
  run through `Flows.upsert_from_document/3` — the exact path `PUT /api/flows/:key` (`./relay
  flow-push`) takes — so a document that the board would refuse fails here, not on the live board.
  """
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Flows.DefaultLibrary

  @code_path Path.expand("../../../.relay/flows/code.json", __DIR__)
  @deploy_path Path.expand("../../../.relay/flows/deploy.json", __DIR__)
  @repo_root Path.expand("../../..", __DIR__)

  defp doc(path), do: path |> File.read!() |> Jason.decode!()

  # A board shaped like RE after RE408: Code has its done sublane, and Deploy sits after Code.
  defp re_board do
    user = insert(:user)
    {:ok, board} = Boards.create_board(user, %{name: "RE board"})
    code = Enum.find(Boards.list_stages(board), &(&1.name == "Code" and is_nil(&1.parent_id)))
    {:ok, _done} = Boards.enable_lane(code, :done)

    {:ok, _deploy} =
      Boards.create_stage(board, %{
        name: "Deploy",
        category: :in_progress,
        type: :work,
        wip_limit: 1,
        after: code
      })

    board
  end

  defp push!(board, key, path) do
    assert {:ok, _tag, flow} = Flows.upsert_from_document(board, key, doc(path))
    flow
  end

  defp node(flow, key), do: Enum.find(flow.nodes, &(&1.key == key))

  defp edge?(flow, from, to, on) do
    Enum.any?(flow.edges, fn e -> e.from == from and e.to == to and Map.get(e, :on) == on end)
  end

  defp edge(flow, from, to, on) do
    Enum.find(flow.edges, fn e -> e.from == from and e.to == to and Map.get(e, :on) == on end)
  end

  defp bin_scripts(run), do: ~r{bin/[\w.-]+} |> Regex.scan(run) |> List.flatten()

  defp executable?(rel) do
    %File.Stat{mode: mode} = File.stat!(Path.join(@repo_root, rel))
    Bitwise.band(mode, 0o111) != 0
  end

  test "code.json pushes over the seeded code flow" do
    assert {:ok, :updated, _flow} = Flows.upsert_from_document(re_board(), "code", doc(@code_path))
  end

  test "deploy.json creates an enabled exclusive flow Code:Done → Deploy → Review" do
    assert {:ok, :created, flow} = Flows.upsert_from_document(re_board(), "deploy", doc(@deploy_path))
    assert flow.enabled == true
    assert flow.isolation == :exclusive
    assert flow.pulls_from_stage.name == "Code:Done"
    assert flow.works_in_stage.name == "Deploy"
    assert flow.lands_on_stage.name == "Review"
  end

  describe "the pushed code flow" do
    setup do
      %{flow: push!(re_board(), "code", @code_path)}
    end

    test "lands on Code:Done", %{flow: flow} do
      assert flow.lands_on_stage.name == "Code:Done"
    end

    test "has no PR-era deploy node", %{flow: flow} do
      refute "deploy" in Enum.map(flow.nodes, & &1.key)
    end

    test "merge ships to main via bin/ship_to_main.sh and writes nothing", %{flow: flow} do
      merge = node(flow, "merge")
      assert merge.run == "bin/ship_to_main.sh {ref}"
      assert merge.writes == []
    end

    test "merge succeeds into await_ci and fails back into resync (max 2 loops)", %{flow: flow} do
      assert edge?(flow, "merge", "await_ci", :succeeded)
      refute edge?(flow, "merge", "post", :succeeded)
      assert %{max_loops: 2} = edge(flow, "merge", "resync", :failed)
    end

    test "await_ci waits for main's CI on the shipped commit before post", %{flow: flow} do
      await_ci = node(flow, "await_ci")
      assert await_ci.type == :shell
      assert await_ci.run == "bin/await_main_ci.sh"
      assert edge?(flow, "await_ci", "post", :succeeded)
    end

    test "a red main CI goes to the ci-fixer agent (max 2 loops), which loops back through resync", %{flow: flow} do
      assert %{max_loops: 2} = edge(flow, "await_ci", "github_fix", :failed)

      github_fix = node(flow, "github_fix")
      assert github_fix.type == :agent
      assert github_fix.agent == "ci-fixer"
      assert edge?(flow, "github_fix", "resync", :succeeded)
      assert edge?(flow, "github_fix", "needs_input", :failed)
    end

    test "flutter is a gate that runs bin/flutter_gate.sh", %{flow: flow} do
      flutter = node(flow, "flutter")
      assert flutter.type == :gate
      assert flutter.run == "bin/flutter_gate.sh"
    end

    test "the flutter gate sits between precommit and browser", %{flow: flow} do
      assert edge?(flow, "precommit", "flutter", :succeeded)
      assert edge?(flow, "flutter", "browser", :succeeded)
      refute edge?(flow, "precommit", "browser", :succeeded)
    end

    test "a failing flutter gate goes to final_fix (max 2 loops), which re-runs precommit", %{flow: flow} do
      assert %{max_loops: 2} = edge(flow, "flutter", "final_fix", :failed)
      assert edge?(flow, "final_fix", "precommit", :succeeded)
    end

    test "the pre-merge tail stays Elixir-only — no flutter gate after reverify or rebrowser", %{flow: flow} do
      refute Enum.any?(flow.edges, &(&1.from in ["reverify", "rebrowser"] and &1.to == "flutter"))
      assert node(flow, "reverify").run == "mix precommit"
    end
  end

  describe "the pushed deploy flow" do
    setup do
      %{flow: push!(re_board(), "deploy", @deploy_path)}
    end

    test "walks checkout → fly → ios → android → done on success", %{flow: flow} do
      walk =
        "start"
        |> Stream.unfold(fn
          nil ->
            nil

          from ->
            case Enum.find(flow.edges, &(&1.from == from and Map.get(&1, :on) in [nil, :succeeded])) do
              nil -> nil
              e -> {e.to, if(e.to == "done", do: nil, else: e.to)}
            end
        end)
        |> Enum.to_list()

      assert walk == ["checkout", "fly", "ios", "android", "done"]
    end

    test "every node is a single-retry shell node that parks on failure", %{flow: flow} do
      for key <- ["checkout", "fly", "ios", "android"] do
        n = node(flow, key)
        assert n.type == :shell, key
        assert n.max_retries == 1, key
        assert edge?(flow, key, "needs_input", :failed), key
      end
    end
  end

  test "the deploy nodes run their scripts directly, reading secrets from the runner's environment" do
    runs = Map.new(doc(@deploy_path)["nodes"], &{&1["key"], &1["run"]})

    assert runs["fly"] == "bin/deploy_fly.sh"
    assert runs["ios"] == "bin/deploy_ios.sh {ref}"
    assert runs["android"] == "bin/deploy_android.sh {ref}"
  end

  test "neither document carries a top-level version" do
    refute Map.has_key?(doc(@code_path), "version")
    refute Map.has_key?(doc(@deploy_path), "version")
  end

  test "every bin/ script the deploy, merge and gate nodes run exists and is executable" do
    deploy_runs = Enum.map(doc(@deploy_path)["nodes"], & &1["run"])
    code_runs = for n <- doc(@code_path)["nodes"], n["key"] in ["merge", "await_ci", "flutter"], do: n["run"]
    scripts = Enum.uniq(Enum.flat_map(code_runs ++ deploy_runs, &bin_scripts/1))

    for s <-
          ~w(bin/deploy_fly.sh bin/deploy_ios.sh bin/deploy_android.sh bin/ship_to_main.sh bin/await_main_ci.sh bin/flutter_gate.sh) do
      assert s in scripts, s
    end

    for s <- scripts, do: assert(executable?(s), "#{s} is missing or not executable")
  end

  test "a trigger naming an unknown stage is refused — the push runs real validation" do
    bad = put_in(doc(@code_path), ["trigger", "lands_on"], "Nowhere")
    assert {:error, {:unknown_stages, ["Nowhere"]}} = Flows.upsert_from_document(re_board(), "code", bad)
  end

  test "the default library's code flow still deploys through a PR and CI" do
    code = Enum.find(DefaultLibrary.all(), &(&1.key == "code"))
    deploy = Enum.find(code.nodes, &(&1.key == "deploy"))
    assert deploy.run =~ "bin/await_deploy.sh"
    assert Enum.find(code.nodes, &(&1.key == "merge")).writes == [:pr_url]
  end
end
