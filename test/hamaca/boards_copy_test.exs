defmodule Hamaca.BoardsCopyTest do
  @moduledoc """
  RE447: `Hamaca.Boards.create_board/2`'s `copy_from` path — a plain copy of a board the user is a
  member of (stages, sub-lanes, WIP limits, reject-to, agents, default agent, disabled flows; no
  cards, no link) — and `Hamaca.Boards.copy_sources/1`, the picker's list of copyable boards.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Agents
  alias Hamaca.Boards
  alias Hamaca.Flows
  alias Hamaca.Repo
  alias Hamaca.Setup
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Flow
  alias Schemas.FlowVersion
  alias Schemas.Stage

  @default_mains ["Backlog", "Next up", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]

  defp mains(board), do: Enum.filter(board.stages, &is_nil(&1.parent_id))
  defp sublane_names(board), do: for(%Stage{parent_id: p, name: n} <- board.stages, not is_nil(p), do: n)
  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))
  defp reload(user, board), do: Boards.get_board(user, board.slug)

  defp definition(flow) do
    {Enum.map(flow.nodes, &Map.take(&1, Flow.Node.fields())), Enum.map(flow.edges, &Map.take(&1, Flow.Edge.fields()))}
  end

  # The default-pipeline board "Hamaca", its "Code" stage limited to 3 cards.
  defp source!(user) do
    {:ok, relay} = Boards.create_board(user, %{name: "Hamaca"})
    {:ok, _} = Boards.update_stage(stage_named(relay, "Code"), %{wip_limit: 3})
    reload(user, relay)
  end

  defp copy!(user, source, name \\ "Untitled board") do
    {:ok, copy} = Boards.create_board(user, %{name: name, copy_from: source.slug})
    copy
  end

  setup do
    user = insert(:user)
    %{user: user, relay: source!(user)}
  end

  # Scenario 1
  test "copies the main stages, sub-lanes and WIP limits onto new stage rows", %{user: user, relay: relay} do
    assert {:ok, copy} = Boards.create_board(user, %{name: "Untitled board", copy_from: relay.slug})

    assert Enum.map(mains(copy), & &1.name) == @default_mains

    assert Enum.map(mains(copy), &{&1.category, &1.type}) == Enum.map(mains(relay), &{&1.category, &1.type})
    assert sublane_names(copy) == sublane_names(relay)
    assert sublane_names(copy) != []
    assert stage_named(copy, "Code").wip_limit == 3

    source_ids = MapSet.new(relay.stages, & &1.id)
    assert Enum.all?(copy.stages, &(not MapSet.member?(source_ids, &1.id)))
  end

  # Scenario 2
  test "reject-to points at the copy's own Plan stage", %{user: user, relay: relay} do
    copy = copy!(user, relay)

    assert stage_named(copy, "Review").reject_to_stage_id == stage_named(copy, "Plan").id
    refute stage_named(copy, "Review").reject_to_stage_id == stage_named(relay, "Plan").id
  end

  # Scenario 3
  test "copies every flow disabled at v1 on the same-named stage, definition intact", %{user: user, relay: relay} do
    copy = copy!(user, relay)
    source_flows = Map.new(Flows.list_flows(relay), &{&1.key, &1})
    copied = Flows.list_flows(copy)

    assert Enum.map(copied, & &1.key) == ["code", "plan", "spec"]

    for flow <- copied do
      source = Map.fetch!(source_flows, flow.key)
      assert flow.board_id == copy.id
      assert flow.stage.board_id == copy.id
      assert flow.stage.name == source.stage.name
      assert flow.enabled == false
      assert flow.version == 1
      assert flow.isolation == source.isolation
      assert definition(flow) == definition(source)
      assert Repo.aggregate(from(v in FlowVersion, where: v.flow_id == ^flow.id), :count) == 1
    end
  end

  # Scenario 4
  test "copies the agents and the default agent", %{user: user, relay: relay} do
    harness = Enum.find(Agents.list_harnesses(relay), &(&1.key == Agents.default_harness_key()))

    {:ok, reviewer} =
      Agents.create_agent(relay, %{"name" => "Reviewer", "harness_id" => harness.id, "model" => "sonnet"})

    {:ok, _} = Agents.set_default_agent(relay, reviewer)

    copy = copy!(user, relay)

    assert Agents.agent_names(copy) == Agents.agent_names(relay)
    assert Agents.default_agent(copy).name == "Reviewer"
    assert Agents.default_agent(copy).board_id == copy.id
    assert Agents.default_agent(copy).harness.board_id == copy.id
  end

  # Scenario 5
  test "copies no cards, no example template and no public intake", %{user: user, relay: relay} do
    backlog = stage_named(relay, "Backlog")
    insert(:card, stage: backlog)
    insert(:card, stage: backlog)

    copy = copy!(user, relay)

    assert Repo.aggregate(from(c in Card, where: c.board_id == ^copy.id), :count) == 0
    stored = Repo.get!(Board, copy.id)
    assert stored.example_template == nil
    assert stored.public_enabled == false
    assert stored.public_intake_stage_id == nil
  end

  # Scenario 6
  test "keeps no link: a later rename on the source doesn't reach the copy", %{user: user, relay: relay} do
    copy = copy!(user, relay)

    {:ok, _} = Boards.update_stage(stage_named(relay, "Plan"), %{name: "Planning"})

    names = Enum.map(mains(reload(user, copy)), & &1.name)
    assert "Plan" in names
    refute "Planning" in names
  end

  # Scenario 7
  test "a board the user isn't a member of, or no board at all, is not found", %{user: user} do
    {:ok, secret} = Boards.create_board(insert(:user), %{name: "Secret"})
    before = Repo.aggregate(Board, :count)

    assert Boards.create_board(user, %{name: "X", slug: unique_slug("x"), copy_from: secret.slug}) == {:error, :not_found}
    assert Repo.aggregate(Board, :count) == before

    assert Boards.create_board(user, %{name: "X", slug: unique_slug("x"), copy_from: "no-such-board"}) ==
             {:error, :not_found}

    assert Repo.aggregate(Board, :count) == before
  end

  # Scenario 8
  test "the copy starts the setup checklist, step 1 reading copied from <source>", %{user: user, relay: relay} do
    checklist = Setup.checklist(copy!(user, relay))
    assert checklist

    one = Enum.find(checklist.steps, &(&1.id == "1"))
    two = Enum.find(checklist.steps, &(&1.id == "2"))
    assert one.status == :done
    assert one.evidence == "copied from Hamaca"
    assert one.data["template"] == "Hamaca"
    assert two.status == :active
  end

  # Scenario 9
  test "a source with no flows copies its stages only", %{user: user, relay: relay} do
    for flow <- Flows.list_flows(relay), do: {:ok, _} = Flows.delete_flow(flow)

    copy = copy!(user, relay)

    assert Enum.map(mains(copy), & &1.name) == @default_mains
    assert Flows.list_flows(copy) == []
  end

  # Scenario 10
  test "copy_sources/1 lists the user's active member boards with counts and referenced files",
       %{user: user, relay: relay} do
    {:ok, old} = Boards.create_board(user, %{name: "Old"})
    {:ok, _} = Boards.archive_board(old)
    {:ok, _other} = Boards.create_board(insert(:user), %{name: "Not mine"})

    files = Flows.referenced_files(Flows.list_flows(relay))

    assert Boards.copy_sources(user) == [
             %{slug: relay.slug, name: "Hamaca", key: relay.key, stages: 8, flows: 3, files: files}
           ]

    assert files != []
    assert Enum.any?(files, &match?(%{kind: :agent, name: "plan-implementer"}, &1))
  end

  # Scenario 11
  test "string keys work, and copy_from wins over a template", %{user: user, relay: relay} do
    {:ok, copy} =
      Boards.create_board(user, %{"name" => "Y", "copy_from" => relay.slug, "template" => "bare-minimum"})

    assert Enum.map(mains(copy), & &1.name) == @default_mains
  end
end
