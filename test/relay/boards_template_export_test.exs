defmodule Relay.BoardsTemplateExportTest do
  @moduledoc "`Relay.Boards.template_parts/1`: a live board's stages and flows in template form."
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows

  @templates_dir Path.expand("../../docs/designs/templates", __DIR__)

  defp create!(slug) do
    {:ok, board} = Boards.create_board(insert(:user), %{name: "T #{slug}", template: slug})
    board
  end

  defp file_parts(slug) do
    @templates_dir
    |> Path.join("#{slug}.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.take(["stages", "flows"])
  end

  # Through JSON, as `prod pull-demo-flows` sees it.
  defp parts!(board), do: board |> Boards.template_parts() |> Jason.encode!() |> Jason.decode!()

  # Three-brain names an agent on its planners, which an export drops; the others name none.
  test "a board created from a template with no node agents exports that template's stages and flows" do
    for slug <- ["bare-minimum", "design-led"] do
      assert parts!(create!(slug)) == file_parts(slug), "#{slug} does not round-trip"
    end
  end

  test "exports a stage's edited WIP limit" do
    board = create!("bare-minimum")
    plan = Enum.find(board.stages, &(&1.name == "Plan"))
    {:ok, _} = Boards.update_stage(plan, %{wip_limit: 7})

    stages = parts!(board)["stages"]
    assert %{"name" => "Plan", "wip_limit" => 7, "sublanes" => ["done"]} = Enum.find(stages, &(&1["name"] == "Plan"))
  end

  test "drops a node's agent, so every node runs on the new board's default" do
    board = create!("bare-minimum")
    flow = Enum.find(Flows.list_flows(board), &(&1.key == "plan"))
    nodes = Enum.map(flow.nodes, &(&1 |> Map.from_struct() |> Map.put(:llm, "Claude Opus")))
    {:ok, _} = Flows.update_flow(flow, %{nodes: nodes})

    plan = Enum.find(parts!(board)["flows"], &(&1["key"] == "plan"))
    assert Enum.all?(plan["nodes"], &(not Map.has_key?(&1, "llm")))
  end
end
