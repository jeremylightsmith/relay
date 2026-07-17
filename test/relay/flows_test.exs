defmodule Relay.FlowsTest do
  use Relay.DataCase, async: true

  alias Relay.Flows
  alias Relay.Repo
  alias Schemas.Flow

  # Stages a flow trigger can point at. Top-level stages are enough here —
  # sub-lane trigger resolution is covered in flows_seed_test.exs (Task 2).
  defp board_with_stages do
    board = insert(:board)
    pulls = insert(:stage, board: board, name: "Next up", position: 1)
    works = insert(:stage, board: board, name: "Spec", category: :planning, type: :planning, position: 2)
    lands = insert(:stage, board: board, name: "Spec:Review", category: :planning, type: :review, position: 3)
    %{board: board, pulls: pulls, works: works, lands: lands}
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        key: "custom",
        isolation: :shared_clean,
        nodes: [%{key: "work", type: :agent, run: "/work {ref}"}],
        edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
      },
      overrides
    )
  end

  # Flow-level graph errors sit directly in changeset.errors; errors_on/1
  # hides them behind the cast embeds, so read them raw.
  defp messages_on(changeset, field) do
    for {^field, {msg, _opts}} <- changeset.errors, do: msg
  end

  defp triggers(ctx) do
    %{pulls_from_stage_id: ctx.pulls.id, works_in_stage_id: ctx.works.id, lands_on_stage_id: ctx.lands.id}
  end

  describe "create_flow/2 and reads" do
    test "creates a valid flow, disabled, and reads it back board-scoped" do
      %{board: board, pulls: pulls, works: works, lands: lands} = board_with_stages()

      assert {:ok, %Flow{} = flow} =
               Flows.create_flow(
                 board,
                 valid_attrs(%{
                   pulls_from_stage_id: pulls.id,
                   works_in_stage_id: works.id,
                   lands_on_stage_id: lands.id
                 })
               )

      assert flow.board_id == board.id
      assert flow.enabled == false
      assert [%Flow{key: "custom"}] = Flows.list_flows(board)
      assert %Flow{key: "custom"} = Flows.get_flow(board, "custom")
      assert Flows.get_flow(insert(:board), "custom") == nil
      assert_raise Ecto.NoResultsError, fn -> Flows.get_flow!(board, "missing") end
    end

    test "list_flows/1 orders by key and preloads trigger stages" do
      %{board: board, pulls: pulls} = board_with_stages()
      {:ok, _} = Flows.create_flow(board, valid_attrs(%{key: "zeta"}))
      {:ok, _} = Flows.create_flow(board, valid_attrs(%{key: "alpha", pulls_from_stage_id: pulls.id}))

      assert [%Flow{key: "alpha"} = alpha, %Flow{key: "zeta"}] = Flows.list_flows(board)
      assert alpha.pulls_from_stage.id == pulls.id
    end

    test "key is unique per board but shared across boards" do
      %{board: board} = board_with_stages()
      {:ok, _} = Flows.create_flow(board, valid_attrs())

      assert {:error, changeset} = Flows.create_flow(board, valid_attrs())
      assert %{key: [_]} = errors_on(changeset)

      assert {:ok, _} = Flows.create_flow(insert(:board), valid_attrs())
    end

    test "update_flow/2 revalidates the graph and replaces embeds" do
      %{board: board} = board_with_stages()
      {:ok, flow} = Flows.create_flow(board, valid_attrs())

      assert {:error, changeset} = Flows.update_flow(flow, %{edges: [%{from: "start", to: "ghost"}]})
      assert ~s(edge to "ghost" does not name a node) in messages_on(changeset, :edges)

      assert {:ok, updated} = Flows.update_flow(flow, %{nodes: [%{key: "work", type: :shell, run: "true"}]})
      assert [%{type: :shell, run: "true"}] = updated.nodes
    end
  end

  describe "graph validation (AC 3)" do
    test "rejects an unknown node type" do
      %{board: board} = board_with_stages()

      assert {:error, changeset} =
               Flows.create_flow(board, valid_attrs(%{nodes: [%{key: "work", type: "teleport", run: "x"}]}))

      assert [%{type: ["is invalid"]}] = errors_on(changeset).nodes
    end

    test "rejects an unknown edge outcome" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: "exploded"}]})

      assert {:error, changeset} = Flows.create_flow(board, attrs)
      assert [%{}, %{on: ["is invalid"]}] = errors_on(changeset).edges
    end

    test "rejects an edge to a node key that doesn't exist" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{
          edges: [%{from: "start", to: "work"}, %{from: "work", to: "missing", on: :succeeded}]
        })

      assert {:error, changeset} = Flows.create_flow(board, attrs)
      assert ~s(edge to "missing" does not name a node) in messages_on(changeset, :edges)
    end

    test "rejects sentinel misuse: an edge out of done or into start" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{edges: [%{from: "start", to: "work"}, %{from: "done", to: "work", on: :succeeded}]})

      assert {:error, changeset} = Flows.create_flow(board, attrs)
      assert ~s(edge from "done" does not name a node) in messages_on(changeset, :edges)

      attrs =
        valid_attrs(%{edges: [%{from: "start", to: "work"}, %{from: "work", to: "start", on: :succeeded}]})

      assert {:error, changeset} = Flows.create_flow(board, attrs)
      assert ~s(edge to "start" does not name a node) in messages_on(changeset, :edges)
    end

    test "rejects node keys named after a sentinel and duplicate node keys" do
      %{board: board} = board_with_stages()

      assert {:error, changeset} =
               Flows.create_flow(
                 board,
                 valid_attrs(%{
                   nodes: [%{key: "start", type: :agent, run: "x"}],
                   edges: [%{from: "start", to: "start"}]
                 })
               )

      assert [%{key: [_]}] = errors_on(changeset).nodes

      assert {:error, changeset} =
               Flows.create_flow(
                 board,
                 valid_attrs(%{
                   nodes: [%{key: "work", type: :agent, run: "a"}, %{key: "work", type: :shell, run: "b"}]
                 })
               )

      assert "node keys must be unique within the flow" in messages_on(changeset, :nodes)
    end

    test "requires exactly one start edge, outcome-less, and outcomes everywhere else" do
      %{board: board} = board_with_stages()

      {:error, changeset} =
        Flows.create_flow(board, valid_attrs(%{edges: [%{from: "work", to: "done", on: :succeeded}]}))

      assert "exactly one edge must leave start" in messages_on(changeset, :edges)

      {:error, changeset} =
        Flows.create_flow(
          board,
          valid_attrs(%{
            edges: [%{from: "start", to: "work", on: :succeeded}, %{from: "work", to: "done", on: :succeeded}]
          })
        )

      assert "the start edge cannot carry an outcome" in messages_on(changeset, :edges)

      {:error, changeset} =
        Flows.create_flow(
          board,
          valid_attrs(%{edges: [%{from: "start", to: "work"}, %{from: "work", to: "done"}]})
        )

      assert "every edge except the start edge requires an outcome" in messages_on(changeset, :edges)
    end

    test "rejects two edges leaving one node on the same outcome" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{
          nodes: [%{key: "work", type: :agent, run: "a"}, %{key: "other", type: :agent, run: "b"}],
          edges: [
            %{from: "start", to: "work"},
            %{from: "work", to: "done", on: :succeeded},
            %{from: "work", to: "other", on: :succeeded}
          ]
        })

      assert {:error, changeset} = Flows.create_flow(board, attrs)
      assert "only one edge may leave a node per outcome" in messages_on(changeset, :edges)
    end

    test "accepts needs_input edges and human/parallel node types as valid data" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{
          nodes: [%{key: "work", type: :agent, run: "a"}, %{key: "ask", type: :human}],
          edges: [
            %{from: "start", to: "work"},
            %{from: "work", to: "ask", on: :needs_input},
            %{from: "work", to: "done", on: :succeeded},
            %{from: "ask", to: "done", on: :succeeded}
          ]
        })

      assert {:ok, _flow} = Flows.create_flow(board, attrs)
    end

    test "rejects non-positive max_retries and max_loops" do
      %{board: board} = board_with_stages()

      assert {:error, changeset} =
               Flows.create_flow(
                 board,
                 valid_attrs(%{nodes: [%{key: "work", type: :agent, run: "x", max_retries: 0}]})
               )

      assert [%{max_retries: [_]}] = errors_on(changeset).nodes

      assert {:error, changeset} =
               Flows.create_flow(
                 board,
                 valid_attrs(%{
                   edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :failed, max_loops: -1}]
                 })
               )

      assert [%{}, %{max_loops: [_]}] = errors_on(changeset).edges
    end

    test "rejects a trigger stage belonging to a different board" do
      %{board: board} = board_with_stages()
      %{pulls: foreign_stage} = board_with_stages()

      assert {:error, changeset} =
               Flows.create_flow(board, valid_attrs(%{pulls_from_stage_id: foreign_stage.id}))

      assert %{pulls_from_stage_id: ["stage is not on this board"]} = errors_on(changeset)
    end
  end

  describe "enable_flow/1 and disable_flow/1" do
    setup do
      board_with_stages()
    end

    test "enables a fully-triggered flow", ctx do
      {:ok, flow} = Flows.create_flow(ctx.board, valid_attrs(triggers(ctx)))

      assert {:ok, %Flow{enabled: true}} = Flows.enable_flow(flow)
    end

    test "refuses to enable a flow with a missing trigger stage (AC 5)", ctx do
      {:ok, flow} =
        Flows.create_flow(
          ctx.board,
          valid_attrs(%{pulls_from_stage_id: ctx.pulls.id, works_in_stage_id: ctx.works.id})
        )

      assert {:error, changeset} = Flows.enable_flow(flow)
      assert %{lands_on_stage_id: ["must be set before the flow can be enabled"]} = errors_on(changeset)
      assert Flows.get_flow(ctx.board, "custom").enabled == false
    end

    test "at most one enabled flow per pulls-from stage (AC 4)", ctx do
      {:ok, first} = Flows.create_flow(ctx.board, valid_attrs(triggers(ctx)))
      {:ok, second} = Flows.create_flow(ctx.board, valid_attrs(Map.put(triggers(ctx), :key, "rival")))

      assert {:ok, _} = Flows.enable_flow(first)
      assert {:error, changeset} = Flows.enable_flow(second)
      assert %{pulls_from_stage_id: ["another enabled flow already pulls from this stage"]} = errors_on(changeset)
      assert Flows.get_flow(ctx.board, "rival").enabled == false
    end

    test "disable_flow/1 frees the pulls-from slot", ctx do
      {:ok, first} = Flows.create_flow(ctx.board, valid_attrs(triggers(ctx)))
      {:ok, second} = Flows.create_flow(ctx.board, valid_attrs(Map.put(triggers(ctx), :key, "rival")))

      {:ok, first} = Flows.enable_flow(first)
      assert {:ok, %Flow{enabled: false}} = Flows.disable_flow(first)
      assert {:ok, %Flow{enabled: true}} = Flows.enable_flow(second)
    end

    test "deleting a trigger stage nilifies the trigger; the flow can't be enabled", ctx do
      {:ok, _flow} = Flows.create_flow(ctx.board, valid_attrs(triggers(ctx)))
      Repo.delete!(ctx.lands)

      flow = Flows.get_flow(ctx.board, "custom")
      assert flow.lands_on_stage_id == nil
      assert {:error, changeset} = Flows.enable_flow(flow)
      assert %{lands_on_stage_id: ["must be set before the flow can be enabled"]} = errors_on(changeset)
    end
  end
end
