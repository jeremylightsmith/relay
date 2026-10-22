defmodule Relay.BoardsTemplatesTest do
  @moduledoc "RE442: the board-template library and `Relay.Boards.create_board/2`'s template path."
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Boards.Templates
  alias Relay.Flows
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Stage

  @slugs ["bare-minimum", "design-led", "three-brain"]

  defp create!(slug) do
    {:ok, board} = Boards.create_board(insert(:user), %{name: "T #{slug}", template: slug})
    board
  end

  defp mains(board), do: Enum.filter(board.stages, &is_nil(&1.parent_id))
  defp sublane_names(board), do: for(%Stage{parent_id: p, name: n} <- board.stages, not is_nil(p), do: n)
  defp stage_name(board, id), do: Enum.find(board.stages, &(&1.id == id)).name
  defp flows_by_key(board), do: Map.new(Flows.list_flows(board), &{&1.key, &1})

  defp flow_stages(board) do
    for flow <- Flows.list_flows(board), do: {flow.key, flow.stage.name, flow.enabled}
  end

  describe "the library" do
    # Scenario 1
    test "slugs/0 is the three templates in picker order, and all/0 follows it" do
      assert Templates.slugs() == @slugs
      assert Enum.map(Templates.all(), & &1.slug) == @slugs
    end

    # Scenario 2
    test "get/1 returns each template's picker copy; an unknown slug is nil" do
      for slug <- @slugs do
        template = Templates.get(slug)
        assert template.slug == slug

        for field <- [:name, :tagline, :blurb] do
          assert is_binary(Map.fetch!(template, field)) and String.trim(Map.fetch!(template, field)) != ""
        end
      end

      assert Templates.get("bare-minimum").warning == nil
      assert Templates.get("design-led").warning == nil
      assert Templates.get("three-brain").warning == "Needs runners signed in to Claude Code, Codex and Gemini CLI"
      assert Templates.get("nope") == nil
      assert Boards.templates() == Templates.all()
      assert Enum.map(Boards.offered_templates(), & &1.slug) == ["bare-minimum", "design-led"]
    end

    # Scenario 3
    test "each JSON file is an external resource" do
      resources =
        :attributes
        |> Templates.__info__()
        |> Keyword.get_values(:external_resource)
        |> List.flatten()
        |> Enum.map(&to_string/1)

      for slug <- @slugs do
        assert Enum.any?(resources, &String.ends_with?(&1, "docs/designs/templates/#{slug}.json")),
               "#{slug}.json is not an @external_resource: #{inspect(resources)}"
      end
    end
  end

  describe "create_board/2 with a template" do
    # Scenario 4
    test "bare-minimum seeds its stages, a Plan:Done sub-lane and two disabled flows" do
      board = create!("bare-minimum")

      assert Enum.map(mains(board), &{&1.name, &1.category, &1.type, &1.wip_limit}) == [
               {"Backlog", :unstarted, :queue, nil},
               {"Plan", :planning, :planning, 3},
               {"Implement", :in_progress, :work, 2},
               {"Review", :in_progress, :review, 3},
               {"Deploy", :in_progress, :work, 2},
               {"Done", :complete, :done, nil}
             ]

      assert sublane_names(board) == ["Plan:Done"]
      assert flow_stages(board) == [{"implement", "Implement", false}, {"plan", "Plan", false}]
    end

    # Scenario 5
    test "design-led (string-keyed attrs) seeds its stages, sub-lanes and three disabled flows" do
      {:ok, board} = Boards.create_board(insert(:user), %{"name" => "DL", "template" => "design-led"})

      assert Enum.map(mains(board), & &1.name) ==
               ["Backlog", "Next up", "Design", "Plan", "Code", "Review", "Deploy", "Done"]

      assert Enum.map(mains(board), & &1.wip_limit) == [nil, 3, 3, 2, 2, 3, 2, nil]
      assert Enum.sort(sublane_names(board)) == Enum.sort(["Design:Review", "Design:Done", "Plan:Review", "Plan:Done"])

      assert flow_stages(board) == [
               {"code", "Code", false},
               {"design", "Design", false},
               {"plan", "Plan", false}
             ]

      refute Enum.any?(board.stages, &(&1.name == "Spec"))
      refute Enum.any?(Flows.list_flows(board), &(&1.stage.name == "Deploy"))
    end

    # Scenario 6
    test "three-brain seeds its stages, flows and the GPT / Gemini agents on their harnesses" do
      board = create!("three-brain")

      assert Enum.map(mains(board), & &1.name) == ["Backlog", "Plan", "Implement", "Review", "Deploy", "Done"]
      assert Enum.map(mains(board), & &1.wip_limit) == [nil, 2, 2, 3, 2, nil]
      assert Enum.sort(sublane_names(board)) == ["Plan:Done", "Plan:Review"]
      assert flow_stages(board) == [{"implement", "Implement", false}, {"three-brain-plan", "Plan", false}]

      agents = Map.new(Relay.Agents.list_agents(board), &{&1.name, &1})

      seed_model = fn key ->
        Relay.Agents.seed_harnesses() |> Enum.find(&(&1.key == key)) |> Map.fetch!(:models) |> hd()
      end

      assert agents["GPT"].harness.key == "codex"
      assert agents["GPT"].model == seed_model.("codex")
      assert agents["Gemini"].harness.key == "gemini-cli"
      assert agents["Gemini"].model == seed_model.("gemini-cli")
      assert Relay.Agents.default_agent(board).name == "Claude Opus"
    end

    # Scenario 7
    test "three-brain-plan fans out to three planners and joins at a judge; implement has no review" do
      flows = flows_by_key(create!("three-brain"))
      plan = flows["three-brain-plan"]
      nodes = Map.new(plan.nodes, &{&1.key, &1})

      assert nodes["split"].type == :fan_out
      assert nodes["join"].type == :fan_in

      assert Map.new(~w(claude_plan gpt_plan gemini_plan judge mockup), &{&1, nodes[&1].llm}) == %{
               "claude_plan" => "Claude Opus",
               "gpt_plan" => "GPT",
               "gemini_plan" => "Gemini",
               "judge" => nil,
               "mockup" => nil
             }

      assert [region] = Schemas.Flow.regions(plan)
      assert region.fan_out == "split"
      assert region.fan_in == "join"
      assert length(region.branches) == 3

      refute Enum.any?(flows["implement"].nodes, &(&1.key == "review"))
    end

    # RE443 Scenario 16
    test "every node runs on the board default except three-brain's three planners" do
      named =
        for slug <- @slugs,
            flow <- Flows.list_flows(create!(slug)),
            node <- flow.nodes,
            node.llm != nil,
            into: %{},
            do: {"#{slug}/#{flow.key}/#{node.key}", node.llm}

      assert named == %{
               "three-brain/three-brain-plan/claude_plan" => "Claude Opus",
               "three-brain/three-brain-plan/gpt_plan" => "GPT",
               "three-brain/three-brain-plan/gemini_plan" => "Gemini"
             }
    end

    # Scenario 8
    test "every template board has a clean flow shape" do
      for slug <- @slugs do
        assert Flows.shape_problems(create!(slug)) == [], "#{slug} has shape problems"
      end
    end

    # Scenario 9
    test "every node is inline (no agent), names a placeholder, uses no bare relay, and routes :failed" do
      for slug <- @slugs, flow <- Flows.list_flows(create!(slug)), node <- flow.nodes do
        where = "#{slug}/#{flow.key}/#{node.key}"
        assert node.agent == nil, "#{where} sets agent"

        if node.type == :agent do
          assert node.run =~ "{relay}" or node.run =~ "{ref}", "#{where} names neither {relay} nor {ref}"
        end

        refute node.run && Regex.match?(~r/(^|[\s`])relay\s/, node.run), "#{where} calls a bare `relay`"

        if node.type in [:agent, :shell, :gate] do
          assert Enum.any?(flow.edges, &(&1.from == node.key and &1.on == :failed)),
                 "#{where} leaves :failed unrouted"
        end
      end
    end

    # Scenario 10
    test "Review rejects back to Plan on every template" do
      for slug <- @slugs do
        board = create!(slug)
        review = Enum.find(mains(board), &(&1.name == "Review"))
        assert stage_name(board, review.reject_to_stage_id) == "Plan", "#{slug} Review does not reject to Plan"
      end
    end

    # Scenario 11
    test "a template brings no cards and never the default 11 stages" do
      for slug <- @slugs do
        board = create!(slug)
        assert Repo.aggregate(from(c in Card, where: c.board_id == ^board.id), :count) == 0
        refute length(board.stages) == 11
      end
    end

    # Scenario 12
    test "an unknown slug returns {:error, :unknown_template} and inserts no board" do
      user = insert(:user)
      before = Repo.aggregate(Board, :count)

      assert Boards.create_board(user, %{name: "X", template: "nope"}) == {:error, :unknown_template}
      assert Repo.aggregate(Board, :count) == before
    end

    # Scenario 13
    test "no template keeps the default 11 stages and the spec / plan / code flows" do
      {:ok, board} = Boards.create_board(insert(:user), %{name: "Plain"})

      assert length(board.stages) == 11
      assert board |> Flows.list_flows() |> Enum.map(& &1.key) == ["code", "plan", "spec"]
    end
  end

  describe "Flows.seed_template_flows!/2" do
    # Scenario 14
    test "raises on a trigger stage the board lacks, and seeds nothing" do
      board = insert(:board)
      flow = %{hd(Templates.get("bare-minimum").flows) | trigger: %{stage: "Nowhere"}}

      assert_raise ArgumentError, ~r/Nowhere/, fn -> Flows.seed_template_flows!(board, [flow]) end
      refute Enum.any?(Flows.list_flows(board), &(&1.key == flow.key))
    end

    # Scenario 15
    test "raises Ecto.InvalidChangesetError when a node's llm names an agent the board lacks" do
      {:ok, board} = Boards.create_board(insert(:user), %{name: "No GPT"})
      # Free the Plan stage so the only problem left is the unknown LLM.
      {:ok, _} = board |> flows_by_key() |> Map.fetch!("plan") |> Flows.delete_flow()

      three_brain_plan =
        Enum.find(Templates.get("three-brain").flows, &(&1.key == "three-brain-plan"))

      error =
        assert_raise Ecto.InvalidChangesetError, fn ->
          Flows.seed_template_flows!(board, [%{three_brain_plan | trigger: %{stage: "Plan"}}])
        end

      assert Enum.any?(error.changeset.errors, fn {:nodes, {message, _}} -> message =~ ~s(LLM "GPT") end)
      refute Map.has_key?(flows_by_key(board), "three-brain-plan")
    end
  end
end
