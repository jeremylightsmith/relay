defmodule Relay.BoardsTemplatesTest do
  @moduledoc "RE442: the board-template library and `Relay.Boards.create_board/2`'s template path."
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Boards.Templates
  alias Relay.Flows
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card

  @slugs ["bare-minimum", "design-led", "three-brain"]

  defp create!(slug) do
    {:ok, board} = Boards.create_board(insert(:user), %{name: "T #{slug}", template: slug})
    board
  end

  defp mains(board), do: Enum.filter(board.stages, &is_nil(&1.parent_id))
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
    # Scenario 4 — a template's content is edited freely (`prod pull-demo-flows`), so these
    # check only that a board gets some stages and disabled flows, never which ones.
    test "every template seeds main stages and disabled flows" do
      for slug <- @slugs do
        board = create!(slug)
        assert mains(board) != [], "#{slug} has no stages"
        assert flow_stages(board) != [], "#{slug} has no flows"
        assert Enum.all?(flow_stages(board), fn {_key, _stage, enabled} -> enabled == false end)
      end
    end

    # Scenario 5
    test "accepts string-keyed attrs" do
      {:ok, board} = Boards.create_board(insert(:user), %{"name" => "DL", "template" => "design-led"})
      assert mains(board) != []
    end

    # Scenario 8
    test "every template board has a clean flow shape" do
      for slug <- @slugs do
        assert Flows.shape_problems(create!(slug)) == [], "#{slug} has shape problems"
      end
    end

    # Scenario 9
    test "every node is inline (no agent), uses no bare relay, and routes :failed" do
      for slug <- @slugs, flow <- Flows.list_flows(create!(slug)), node <- flow.nodes do
        where = "#{slug}/#{flow.key}/#{node.key}"
        assert node.agent == nil, "#{where} sets agent"

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
