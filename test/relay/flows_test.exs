defmodule Relay.FlowsTest do
  use Relay.DataCase, async: true

  alias Relay.Flows
  alias Relay.Repo
  alias Schemas.Flow

  # A board with a planning stage a flow can sit on (RE429: a flow belongs to one main
  # work/planning stage); its neighbours are worked out from board order.
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

  defp triggers(ctx), do: %{stage_id: ctx.works.id}

  # A stage holds one flow (RE429), so a test that only cares about the graph gets a fresh main
  # work stage of its own unless it names one.
  defp create_flow(board, attrs) do
    Flows.create_flow(
      board,
      Map.put_new_lazy(attrs, :stage_id, fn -> insert(:stage, board: board, type: :work, category: :in_progress).id end)
    )
  end

  describe "create_flow/2 and reads" do
    test "creates a valid flow, disabled, and reads it back board-scoped" do
      %{board: board, works: works} = board_with_stages()

      assert {:ok, %Flow{} = flow} = Flows.create_flow(board, valid_attrs(%{stage_id: works.id}))

      assert flow.board_id == board.id
      assert flow.stage_id == works.id
      assert flow.enabled == false
      assert [%Flow{key: "custom"}] = Flows.list_flows(board)
      assert %Flow{key: "custom"} = Flows.get_flow(board, "custom")
      assert Flows.get_flow(insert(:board), "custom") == nil
      assert_raise Ecto.NoResultsError, fn -> Flows.get_flow!(board, "missing") end
    end

    test "list_flows/1 orders by key, preloads the stage and derives its neighbours" do
      %{board: board, pulls: pulls, works: works, lands: lands} = board_with_stages()
      {:ok, _} = create_flow(board, valid_attrs(%{key: "zeta"}))
      {:ok, _} = create_flow(board, valid_attrs(%{key: "alpha", stage_id: works.id}))

      assert [%Flow{key: "alpha"} = alpha, %Flow{key: "zeta"}] = Flows.list_flows(board)
      assert alpha.stage.id == works.id
      assert alpha.pulls_from_stage.id == pulls.id
      assert alpha.lands_on_stage.id == lands.id
    end

    test "key is unique per board but shared across boards" do
      %{board: board} = board_with_stages()
      {:ok, _} = create_flow(board, valid_attrs())

      assert {:error, changeset} = create_flow(board, valid_attrs())
      assert %{key: [_]} = errors_on(changeset)

      assert {:ok, _} = create_flow(insert(:board), valid_attrs())
    end

    test "update_flow/2 revalidates the graph and replaces embeds" do
      %{board: board} = board_with_stages()
      {:ok, flow} = create_flow(board, valid_attrs())

      assert {:error, changeset} = Flows.update_flow(flow, %{edges: [%{from: "start", to: "ghost"}]})
      assert ~s(edge to "ghost" does not name a node) in messages_on(changeset, :edges)

      assert {:ok, updated} = Flows.update_flow(flow, %{nodes: [%{key: "work", type: :shell, run: "true"}]})
      assert [%{type: :shell, run: "true"}] = updated.nodes
    end

    test "accepts two guarded edges leaving one node on the same outcome" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{
          nodes: [
            %{key: "work", type: :agent, run: "a", foreach: "card.tasks"},
            %{key: "after", type: :gate, run: "true"}
          ],
          edges: [
            %{from: "start", to: "work"},
            %{from: "work", to: "work", on: :succeeded, when: :foreach_remaining},
            %{from: "work", to: "after", on: :succeeded, when: :foreach_exhausted},
            %{from: "after", to: "done", on: :succeeded}
          ]
        })

      assert {:ok, flow} = create_flow(board, attrs)
      assert %{foreach: "card.tasks"} = Enum.find(flow.nodes, &(&1.key == "work"))
      assert %{when: :foreach_remaining} = Enum.find(flow.edges, &(&1.to == "work" and &1.from == "work"))
    end

    test "a flow created with legacy sub_tasks spellings is stored canonical (RE367)" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{
          nodes: [
            %{key: "work", type: :agent, run: "a {sub_task_id}", foreach: "card.sub_tasks", reads: [:sub_tasks]},
            %{key: "after", type: :gate, run: "true"}
          ],
          edges: [
            %{from: "start", to: "work"},
            %{from: "work", to: "work", on: :succeeded, when: :foreach_remaining},
            %{from: "work", to: "after", on: :succeeded, when: :foreach_exhausted},
            %{from: "after", to: "done", on: :succeeded}
          ]
        })

      assert {:ok, flow} = create_flow(board, attrs)
      assert %{foreach: "card.tasks", reads: [:tasks], run: "a {task_id}"} = Enum.find(flow.nodes, &(&1.key == "work"))
    end

    test "still rejects two UNGUARDED edges on one route" do
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

      assert {:error, changeset} = create_flow(board, attrs)
      assert "only one edge may leave a node per outcome" in messages_on(changeset, :edges)
    end

    test "rejects a guarded edge in a flow with no foreach node" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{
          nodes: [%{key: "work", type: :agent, run: "a"}],
          edges: [
            %{from: "start", to: "work"},
            %{from: "work", to: "done", on: :succeeded, when: :foreach_exhausted}
          ]
        })

      assert {:error, changeset} = create_flow(board, attrs)
      assert "a flow with guarded edges must have exactly one foreach node" in messages_on(changeset, :edges)
    end

    test "rejects an unknown foreach source" do
      %{board: board} = board_with_stages()

      attrs = valid_attrs(%{nodes: [%{key: "work", type: :agent, run: "a", foreach: "card.comments"}]})

      assert {:error, changeset} = create_flow(board, attrs)
      assert %{nodes: [%{foreach: [~s(must be "card.tasks")]}]} = errors_on(changeset)
    end

    test "an agent node may name its .claude/agents definition; other node types may not" do
      %{board: board} = board_with_stages()

      ok = valid_attrs(%{nodes: [%{key: "work", type: :agent, run: "a", agent: "plan-implementer"}]})
      assert {:ok, flow} = create_flow(board, ok)
      assert %{agent: "plan-implementer"} = Enum.find(flow.nodes, &(&1.key == "work"))

      bad =
        valid_attrs(%{
          key: "custom-2",
          nodes: [%{key: "work", type: :gate, run: "true", agent: "plan-implementer"}]
        })

      assert {:error, changeset} = create_flow(board, bad)
      assert %{nodes: [%{agent: ["is only valid on an agent node"]}]} = errors_on(changeset)
    end

    test "expects_commits casts on an agent node, defaults false, and is rejected elsewhere" do
      %{board: board} = board_with_stages()

      ok = valid_attrs(%{nodes: [%{key: "work", type: :agent, run: "a", expects_commits: true}]})
      assert {:ok, flow} = create_flow(board, ok)
      assert %{expects_commits: true} = Enum.find(flow.nodes, &(&1.key == "work"))

      default = valid_attrs(%{key: "custom-ec", nodes: [%{key: "work", type: :agent, run: "a"}]})
      assert {:ok, flow} = create_flow(board, default)
      assert %{expects_commits: false} = Enum.find(flow.nodes, &(&1.key == "work"))

      bad =
        valid_attrs(%{
          key: "custom-ec2",
          nodes: [%{key: "work", type: :gate, run: "true", expects_commits: true}]
        })

      assert {:error, changeset} = create_flow(board, bad)
      assert %{nodes: [%{expects_commits: ["is only valid on an agent node"]}]} = errors_on(changeset)
    end

    test "the card contract casts on any node type, defaults to empty, and rejects an unknown field" do
      %{board: board} = board_with_stages()

      ok =
        valid_attrs(%{
          nodes: [%{key: "work", type: :agent, run: "a", reads: [:spec], writes: [:plan]}]
        })

      assert {:ok, flow} = create_flow(board, ok)
      assert %{reads: [:spec], writes: [:plan]} = Enum.find(flow.nodes, &(&1.key == "work"))

      default = valid_attrs(%{key: "custom-c0", nodes: [%{key: "work", type: :agent, run: "a"}]})
      assert {:ok, flow} = create_flow(board, default)
      assert %{reads: [], writes: []} = Enum.find(flow.nodes, &(&1.key == "work"))

      # NOT agent-only: the Code flow's `branch` node is a shell node that writes `branch`.
      shell =
        valid_attrs(%{
          key: "custom-c1",
          nodes: [%{key: "work", type: :shell, run: "true", writes: [:branch]}]
        })

      assert {:ok, flow} = create_flow(board, shell)
      assert %{writes: [:branch]} = Enum.find(flow.nodes, &(&1.key == "work"))

      bad =
        valid_attrs(%{
          key: "custom-c2",
          nodes: [%{key: "work", type: :agent, run: "a", writes: [:nonsense_field]}]
        })

      assert {:error, changeset} = create_flow(board, bad)
      assert %{nodes: [%{writes: ["is invalid"]}]} = errors_on(changeset)
    end
  end

  describe "copy_flow/2 and save_definition/2 round-trip foreach/when (regression)" do
    defp free_stage(board), do: insert(:stage, board: board, type: :work, category: :in_progress)

    defp foreach_attrs do
      valid_attrs(%{
        nodes: [
          %{key: "work", type: :agent, run: "a", foreach: "card.tasks"},
          %{key: "after", type: :gate, run: "true"}
        ],
        edges: [
          %{from: "start", to: "work"},
          %{from: "work", to: "work", on: :succeeded, when: :foreach_remaining},
          %{from: "work", to: "after", on: :succeeded, when: :foreach_exhausted},
          %{from: "after", to: "done", on: :succeeded}
        ]
      })
    end

    test "copy_flow/2 preserves foreach and when instead of stripping them" do
      %{board: board} = board_with_stages()
      {:ok, original} = create_flow(board, foreach_attrs())

      assert {:ok, copy} = Flows.copy_flow(original, free_stage(board))
      assert %{foreach: "card.tasks"} = Enum.find(copy.nodes, &(&1.key == "work"))
      assert %{when: :foreach_remaining} = Enum.find(copy.edges, &(&1.from == "work" and &1.to == "work"))
      assert %{when: :foreach_exhausted} = Enum.find(copy.edges, &(&1.from == "work" and &1.to == "after"))
    end

    test "save_definition/2 preserves foreach and when in both the flow and its snapshot" do
      %{board: board} = board_with_stages()
      {:ok, flow} = create_flow(board, foreach_attrs())

      assert {:ok, updated} = Flows.save_definition(flow, %{isolation: :exclusive})
      assert %{foreach: "card.tasks"} = Enum.find(updated.nodes, &(&1.key == "work"))

      snapshot = Flows.get_version(updated, updated.version)
      assert %{foreach: "card.tasks"} = Enum.find(snapshot.nodes, &(&1.key == "work"))
      assert %{when: :foreach_remaining} = Enum.find(snapshot.edges, &(&1.from == "work" and &1.to == "work"))
    end

    test "save_definition/2 flags a foreach-only change as a definition change (bumps version)" do
      %{board: board} = board_with_stages()
      {:ok, flow} = create_flow(board, foreach_attrs())

      unguarded_attrs =
        foreach_attrs()
        |> Map.put(:nodes, [%{key: "work", type: :agent, run: "a"}, %{key: "after", type: :gate, run: "true"}])
        |> Map.put(:edges, [
          %{from: "start", to: "work"},
          %{from: "work", to: "after", on: :succeeded},
          %{from: "after", to: "done", on: :succeeded}
        ])

      assert {:ok, updated} = Flows.save_definition(flow, unguarded_attrs)
      assert updated.version == flow.version + 1
      assert Enum.find(updated.nodes, &(&1.key == "work")).foreach == nil
    end

    defp agent_attrs do
      valid_attrs(%{nodes: [%{key: "work", type: :agent, run: "a", agent: "plan-implementer"}]})
    end

    test "copy_flow/2 preserves agent instead of stripping it" do
      %{board: board} = board_with_stages()
      {:ok, original} = create_flow(board, agent_attrs())

      assert {:ok, copy} = Flows.copy_flow(original, free_stage(board))
      assert %{agent: "plan-implementer"} = Enum.find(copy.nodes, &(&1.key == "work"))
    end

    test "save_definition/2 preserves agent in both the flow and its snapshot" do
      %{board: board} = board_with_stages()
      {:ok, flow} = create_flow(board, agent_attrs())

      assert {:ok, updated} = Flows.save_definition(flow, %{isolation: :exclusive})
      assert %{agent: "plan-implementer"} = Enum.find(updated.nodes, &(&1.key == "work"))

      snapshot = Flows.get_version(updated, updated.version)
      assert %{agent: "plan-implementer"} = Enum.find(snapshot.nodes, &(&1.key == "work"))
    end
  end

  describe "graph validation (AC 3)" do
    test "rejects an unknown node type" do
      %{board: board} = board_with_stages()

      assert {:error, changeset} =
               create_flow(board, valid_attrs(%{nodes: [%{key: "work", type: "teleport", run: "x"}]}))

      assert [%{type: ["is invalid"]}] = errors_on(changeset).nodes
    end

    test "rejects an unknown edge outcome" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: "exploded"}]})

      assert {:error, changeset} = create_flow(board, attrs)
      assert [%{}, %{on: ["is invalid"]}] = errors_on(changeset).edges
    end

    test "rejects an edge to a node key that doesn't exist" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{
          edges: [%{from: "start", to: "work"}, %{from: "work", to: "missing", on: :succeeded}]
        })

      assert {:error, changeset} = create_flow(board, attrs)
      assert ~s(edge to "missing" does not name a node) in messages_on(changeset, :edges)
    end

    test "rejects sentinel misuse: an edge out of done or into start" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{edges: [%{from: "start", to: "work"}, %{from: "done", to: "work", on: :succeeded}]})

      assert {:error, changeset} = create_flow(board, attrs)
      assert ~s(edge from "done" does not name a node) in messages_on(changeset, :edges)

      attrs =
        valid_attrs(%{edges: [%{from: "start", to: "work"}, %{from: "work", to: "start", on: :succeeded}]})

      assert {:error, changeset} = create_flow(board, attrs)
      assert ~s(edge to "start" does not name a node) in messages_on(changeset, :edges)
    end

    test "\"needs_input\" is a valid to-endpoint but never a from-endpoint" do
      %{board: board} = board_with_stages()

      ok =
        valid_attrs(%{
          nodes: [%{key: "work", type: :agent, run: "a"}],
          edges: [
            %{from: "start", to: "work"},
            %{from: "work", to: "done", on: :succeeded},
            %{from: "work", to: "needs_input", on: :failed}
          ]
        })

      assert {:ok, _flow} = create_flow(board, ok)

      bad_from =
        valid_attrs(%{
          key: "custom-ni",
          edges: [%{from: "start", to: "work"}, %{from: "needs_input", to: "work", on: :succeeded}]
        })

      assert {:error, changeset} = create_flow(board, bad_from)
      assert ~s(edge from "needs_input" does not name a node) in messages_on(changeset, :edges)
    end

    test "a node keyed \"needs_input\" is rejected as a reserved sentinel" do
      %{board: board} = board_with_stages()

      assert {:error, changeset} =
               create_flow(
                 board,
                 valid_attrs(%{
                   nodes: [%{key: "needs_input", type: :agent, run: "x"}],
                   edges: [%{from: "start", to: "needs_input"}]
                 })
               )

      assert [%{key: [_]}] = errors_on(changeset).nodes
    end

    test "rejects node keys named after a sentinel and duplicate node keys" do
      %{board: board} = board_with_stages()

      assert {:error, changeset} =
               create_flow(
                 board,
                 valid_attrs(%{
                   nodes: [%{key: "start", type: :agent, run: "x"}],
                   edges: [%{from: "start", to: "start"}]
                 })
               )

      assert [%{key: [_]}] = errors_on(changeset).nodes

      assert {:error, changeset} =
               create_flow(
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
        create_flow(board, valid_attrs(%{edges: [%{from: "work", to: "done", on: :succeeded}]}))

      assert "exactly one edge must leave start" in messages_on(changeset, :edges)

      {:error, changeset} =
        create_flow(
          board,
          valid_attrs(%{
            edges: [%{from: "start", to: "work", on: :succeeded}, %{from: "work", to: "done", on: :succeeded}]
          })
        )

      assert "the start edge cannot carry an outcome" in messages_on(changeset, :edges)

      {:error, changeset} =
        create_flow(
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

      assert {:error, changeset} = create_flow(board, attrs)
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

      assert {:ok, _flow} = create_flow(board, attrs)
    end

    test "rejects non-positive max_retries and max_loops" do
      %{board: board} = board_with_stages()

      assert {:error, changeset} =
               create_flow(
                 board,
                 valid_attrs(%{nodes: [%{key: "work", type: :agent, run: "x", max_retries: 0}]})
               )

      assert [%{max_retries: [_]}] = errors_on(changeset).nodes

      assert {:error, changeset} =
               create_flow(
                 board,
                 valid_attrs(%{
                   edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :failed, max_loops: -1}]
                 })
               )

      assert [%{}, %{max_loops: [_]}] = errors_on(changeset).edges
    end

    test "timeout_minutes casts and must be positive" do
      %{board: board} = board_with_stages()

      attrs =
        valid_attrs(%{
          nodes: [%{key: "work", type: :agent, run: "go", timeout_minutes: 25}]
        })

      assert {:ok, flow} = create_flow(board, attrs)
      assert [%{timeout_minutes: 25}] = flow.nodes

      assert {:error, changeset} =
               create_flow(board, valid_attrs(%{nodes: [%{key: "w", type: :agent, timeout_minutes: 0}]}))

      assert %{nodes: [%{timeout_minutes: ["must be greater than 0"]}]} = errors_on(changeset)
    end

    test "rejects a stage belonging to a different board" do
      %{board: board} = board_with_stages()
      %{works: foreign_stage} = board_with_stages()

      assert {:error, changeset} = create_flow(board, valid_attrs(%{stage_id: foreign_stage.id}))

      assert %{stage_id: ["stage is not on this board"]} = errors_on(changeset)
    end
  end

  describe "enable_flow/1 and disable_flow/1" do
    setup do
      board_with_stages()
    end

    test "enables a flow; disable_flow/1 turns it back off", ctx do
      {:ok, flow} = create_flow(ctx.board, valid_attrs(triggers(ctx)))

      assert {:ok, %Flow{enabled: true} = flow} = Flows.enable_flow(flow)
      assert {:ok, %Flow{enabled: false}} = Flows.disable_flow(flow)
    end

    test "deleting the flow's stage deletes the flow (RE429)", ctx do
      {:ok, _flow} = create_flow(ctx.board, valid_attrs(triggers(ctx)))
      Repo.delete!(ctx.works)

      assert Flows.get_flow(ctx.board, "custom") == nil
    end
  end

  describe "stage_flows/1 (RE409)" do
    setup do
      board = insert(:board)
      a = insert(:stage, board: board, type: :work, category: :in_progress)
      b = insert(:stage, board: board, type: :work, category: :in_progress)
      %{board: board, a: a, b: b}
    end

    test "a board with no flows has no AI stages", %{board: board, a: a} do
      assert Flows.stage_flows(board) == %{}
      assert Flows.ai_stage_ids(board) == MapSet.new()
      assert Flows.ai_stage?(a) == false
    end

    test "an enabled flow on a stage maps it to that flow", %{board: board, a: a} do
      insert_flow_working_in(a, key: "code", enabled: true)

      assert Flows.stage_flows(board) == %{a.id => %{key: "code", enabled: true, version: 1}}
    end

    test "a disabled flow still makes its stage AI-enabled", %{board: board, a: a} do
      insert_flow_working_in(a, key: "plan")

      assert Flows.stage_flows(board) == %{a.id => %{key: "plan", enabled: false, version: 1}}
      assert Flows.ai_stage?(a) == true
    end

    test "a second flow can't share a stage (flows_stage_id_index)", %{a: a} do
      insert_flow_working_in(a, key: "first")

      assert_raise Ecto.ConstraintError, fn -> insert_flow_working_in(a, key: "second") end
    end
  end

  describe "ai_stage_ids/1 and ai_stage?/1 (RE409)" do
    test "are scoped to the board and accept a struct or an id" do
      board1 = insert(:board)
      a = insert(:stage, board: board1, type: :work)
      b = insert(:stage, board: board1, type: :work)
      without_flow = insert(:stage, board: board1, type: :work)
      board2 = insert(:board)
      c = insert(:stage, board: board2, type: :work)

      insert_flow_working_in(a, key: "code", enabled: true)
      insert_flow_working_in(b, key: "plan")
      insert_flow_working_in(c, key: "code", enabled: true)

      assert Flows.ai_stage_ids(board1) == MapSet.new([a.id, b.id])
      assert Flows.ai_stage_ids(board1.id) == MapSet.new([a.id, b.id])
      assert Flows.ai_stage?(a.id) == true
      assert Flows.ai_stage?(b) == true
      assert Flows.ai_stage?(without_flow) == false
    end
  end

  describe "list_enabled_flows/1" do
    test "returns only enabled flows, in key order" do
      board = insert(:board)

      # each flow gets its own stage — a stage holds at most one flow (RE429).
      on = fn key, enabled -> insert(:flow, board: board, key: key, enabled: enabled) end

      _b = on.("b-flow", true)
      _a = on.("a-flow", true)
      _off = on.("c-flow", false)

      keys = board |> Flows.list_enabled_flows() |> Enum.map(& &1.key)
      assert keys == ["a-flow", "b-flow"]
    end
  end

  describe "list_enabled_flow_snapshots/1 (RE402)" do
    test "projects only enabled flows, in key order, to %{key, stage_id, isolation}" do
      board = insert(:board)
      on = fn key, enabled -> insert(:flow, board: board, key: key, enabled: enabled) end

      b = on.("b", true)
      a = on.("a", true)
      _off = on.("c", false)

      snaps = Flows.list_enabled_flow_snapshots(board.id)

      assert Enum.map(snaps, & &1.key) == board |> Flows.list_enabled_flows() |> Enum.map(& &1.key)

      assert [
               %{key: "a", stage_id: a.stage_id, isolation: a.isolation},
               %{key: "b", stage_id: b.stage_id, isolation: b.isolation}
             ] == snaps
    end
  end

  describe "delete_flow/1" do
    test "deletes a disabled flow and cascades its version snapshots" do
      ctx = board_with_stages()
      {:ok, flow} = create_flow(ctx.board, valid_attrs(triggers(ctx)))

      assert Flows.get_version(flow, 1)
      assert {:ok, %Flow{}} = Flows.delete_flow(flow)
      assert Flows.get_flow(ctx.board, "custom") == nil
      refute Flows.get_version(flow, 1)
    end

    test "refuses to delete an enabled flow" do
      ctx = board_with_stages()
      {:ok, flow} = create_flow(ctx.board, valid_attrs(triggers(ctx)))
      {:ok, flow} = Flows.enable_flow(flow)

      assert {:error, :flow_enabled} = Flows.delete_flow(flow)
      assert Flows.get_flow(ctx.board, "custom")
    end

    test "deleting a disabled flow nil-s the flow_id of its active runs" do
      ctx = board_with_stages()
      {:ok, flow} = create_flow(ctx.board, valid_attrs(triggers(ctx)))
      run = insert(:run, flow_id: flow.id, status: :running)

      assert {:ok, _} = Flows.delete_flow(flow)
      assert Repo.reload(run).flow_id == nil
    end
  end

  # RE429: a flow belongs to exactly one main work/planning stage; pickup and drop-off are
  # worked out from board order. The default board seeds `spec` on Spec, `plan` on Plan and
  # `code` on Code (all disabled); Deploy is the only flow-free work stage.
  describe "one stage per flow (RE429)" do
    setup do
      {:ok, board} = Relay.Boards.create_board(insert(:user), %{name: "One stage"})
      stages = Map.new(Repo.all(from s in Schemas.Stage, where: s.board_id == ^board.id), &{&1.name, &1})
      %{board: board, stages: stages, code_flow: Flows.get_flow(board, "code")}
    end

    defp one_stage_attrs(stage_id, overrides \\ %{}) do
      Map.merge(
        %{key: "qa", isolation: :shared_clean, stage_id: stage_id, nodes: [], edges: [%{from: "start", to: "done"}]},
        overrides
      )
    end

    defp flow_count(board), do: Repo.aggregate(from(f in Flow, where: f.board_id == ^board.id), :count)

    test "1. a stage that already holds a flow refuses a second one, naming the occupant", ctx do
      before = flow_count(ctx.board)

      assert {:error, cs} = Flows.create_flow(ctx.board, one_stage_attrs(ctx.stages["Code"].id))
      assert "stage already has flow `code`" in errors_on(cs).stage_id
      assert flow_count(ctx.board) == before
    end

    test "2. a disabled flow still occupies its stage", ctx do
      refute ctx.code_flow.enabled

      assert {:error, cs} = Flows.create_flow(ctx.board, one_stage_attrs(ctx.stages["Code"].id))
      assert "stage already has flow `code`" in errors_on(cs).stage_id
    end

    test "3. flows attach to main work/planning stages only", ctx do
      assert {:error, cs} = Flows.create_flow(ctx.board, one_stage_attrs(ctx.stages["Spec:Review"].id))
      assert "flows attach to main stages only, not substages" in errors_on(cs).stage_id

      for name <- ["Next up", "Review", "Done"] do
        assert {:error, cs} = Flows.create_flow(ctx.board, one_stage_attrs(ctx.stages[name].id))
        assert "a flow can only work in a work or planning stage" in errors_on(cs).stage_id
      end
    end

    test "4. the stage must be on the flow's board and is required", ctx do
      {:ok, other} = Relay.Boards.create_board(insert(:user), %{name: "Other"})
      other_deploy = Repo.get_by!(Schemas.Stage, board_id: other.id, name: "Deploy")

      assert {:error, cs} = Flows.create_flow(ctx.board, one_stage_attrs(other_deploy.id))
      assert "stage is not on this board" in errors_on(cs).stage_id

      assert {:error, cs} = Flows.create_flow(ctx.board, Map.delete(one_stage_attrs(nil), :stage_id))
      assert "can't be blank" in errors_on(cs).stage_id
    end

    test "5. a flow created on Deploy reads back with its derived neighbours", ctx do
      deploy = ctx.stages["Deploy"]

      assert {:ok, flow} = Flows.create_flow(ctx.board, one_stage_attrs(deploy.id))
      assert flow.stage_id == deploy.id
      assert flow.enabled == false

      read = Flows.get_flow_with_stages(ctx.board, "qa")
      assert read.stage.name == "Deploy"
      assert read.pulls_from_stage.name == "Review"
      assert read.lands_on_stage.name == "Done"
    end

    test "6. update_flow/2 refuses an occupied stage but allows the flow's own", ctx do
      {:ok, flow} = Flows.create_flow(ctx.board, one_stage_attrs(ctx.stages["Deploy"].id))

      assert {:error, cs} = Flows.update_flow(flow, %{stage_id: ctx.stages["Code"].id})
      assert "stage already has flow `code`" in errors_on(cs).stage_id

      assert {:ok, _} = Flows.update_flow(flow, %{stage_id: ctx.stages["Deploy"].id})
    end

    test "7. stage_flows/1 maps each flow's stage to its key, enabled and version", ctx do
      assert Flows.stage_flows(ctx.board) == %{
               ctx.stages["Spec"].id => %{key: "spec", enabled: false, version: 1},
               ctx.stages["Plan"].id => %{key: "plan", enabled: false, version: 1},
               ctx.stages["Code"].id => %{key: "code", enabled: false, version: 1}
             }
    end

    test "8. the enabled-flow readers key on stage_id", ctx do
      code = ctx.stages["Code"]
      {:ok, code_flow} = Flows.enable_flow(ctx.code_flow)

      assert Flows.list_enabled_flow_snapshots(ctx.board.id) == [
               %{key: "code", stage_id: code.id, isolation: code_flow.isolation}
             ]

      assert %Flow{key: "code"} = Flows.working_flow(%Schemas.Card{board_id: ctx.board.id, stage_id: code.id})
      assert Flows.stage_flow(ctx.stages["Deploy"]) == nil
      assert Flows.ai_stage?(code)
      refute Flows.ai_stage?(ctx.stages["Deploy"])
    end

    test "9. assignable_stages/2 lists empty main work stages plus the flow's own", ctx do
      assert Enum.map(Flows.assignable_stages(ctx.board, nil), & &1.name) == ["Deploy"]
      assert Enum.map(Flows.assignable_stages(ctx.board, ctx.code_flow), & &1.name) == ["Code", "Deploy"]
    end

    test "10. neighbours/1 reads the flow's board order fresh", ctx do
      assert %{pulls_from: pulls_from, lands_on: lands_on} = Flows.neighbours(ctx.code_flow)
      assert pulls_from.name == "Plan:Done"
      assert lands_on.name == "Review"
    end

    test "11. copy_flow/2 copies the definition onto an empty stage, disabled, at v1", ctx do
      {:ok, code_flow} =
        Flows.save_definition(ctx.code_flow, %{
          nodes: [%{key: "a", type: :shell, run: "true"}, %{key: "b", type: :shell, run: "true"}],
          edges: [
            %{from: "start", to: "a"},
            %{from: "a", to: "b", on: :succeeded},
            %{from: "b", to: "done", on: :succeeded}
          ]
        })

      {:ok, code_flow} = Flows.enable_flow(code_flow)
      deploy = ctx.stages["Deploy"]

      assert {:ok, copy} = Flows.copy_flow(code_flow, deploy)
      assert copy.key == "code-deploy"
      assert copy.enabled == false
      assert copy.stage_id == deploy.id
      assert copy.version == 1
      assert Enum.map(copy.nodes, &{&1.key, &1.run}) == [{"a", "true"}, {"b", "true"}]
      assert Enum.map(copy.edges, &{&1.from, &1.to, &1.on}) == Enum.map(code_flow.edges, &{&1.from, &1.to, &1.on})
      assert copy.isolation == code_flow.isolation
      assert %Schemas.FlowVersion{} = Flows.get_version(copy, 1)

      assert {:error, cs} = Flows.copy_flow(code_flow, ctx.stages["Plan"])
      assert "stage already has flow `plan`" in errors_on(cs).stage_id
    end

    test "12. copy_flow/2 suffixes a taken key", ctx do
      {:ok, qa} = Relay.Boards.create_stage(ctx.board, %{name: "QA", category: :in_progress})
      assert qa.type == :work
      {:ok, _} = Flows.create_flow(ctx.board, one_stage_attrs(ctx.stages["Deploy"].id, %{key: "code-qa"}))

      assert {:ok, copy} = Flows.copy_flow(ctx.code_flow, qa)
      assert copy.key == "code-qa-2"
      assert copy.stage_id == qa.id
    end

    test "13. enable_flow/1 has no trigger-completeness check", ctx do
      {:ok, flow} = Flows.create_flow(ctx.board, one_stage_attrs(ctx.stages["Deploy"].id))

      assert {:ok, %Flow{enabled: true}} = Flows.enable_flow(flow)
    end

    test "RE431 1. addable_defaults/1 lists library keys missing from the board", ctx do
      assert Flows.addable_defaults(ctx.board) == []

      {:ok, _} = Flows.delete_flow(ctx.code_flow)
      assert Flows.addable_defaults(ctx.board) == ["code"]
      assert Flows.addable_defaults(ctx.board.id) == ["code"]
    end

    test "RE431 2. add_flow/2 seeds a library flow onto a free stage, disabled, at v1", ctx do
      {:ok, _} = Flows.delete_flow(ctx.code_flow)
      deploy = ctx.stages["Deploy"]
      deploy_id = deploy.id

      assert {:ok, %Flow{key: "code", enabled: false, version: 1, stage_id: ^deploy_id} = flow} =
               Flows.add_flow(deploy, {:default, "code"})

      assert length(flow.nodes) == 21
      assert Flows.customized?(flow) == false
      assert %Schemas.FlowVersion{} = Flows.get_version(flow, 1)
    end

    test "RE431 3. add_flow/2 :blank makes a start→done flow keyed by the stage slug", ctx do
      {:ok, qa} = Relay.Boards.create_stage(ctx.board, %{name: "QA", category: :in_progress})

      assert {:ok, flow} = Flows.add_flow(qa, :blank)
      assert flow.key == "qa"
      assert flow.nodes == []
      assert Enum.map(flow.edges, &{&1.from, &1.to}) == [{"start", "done"}]
      assert flow.isolation == :shared_clean
      assert flow.enabled == false
      assert flow.stage_id == qa.id
    end

    test "RE431 3b. add_flow/2 :blank suffixes a taken slug key", ctx do
      {:ok, _} = Flows.create_flow(ctx.board, one_stage_attrs(ctx.stages["Deploy"].id, %{key: "qa"}))
      {:ok, qa} = Relay.Boards.create_stage(ctx.board, %{name: "QA", category: :in_progress})

      assert {:ok, flow} = Flows.add_flow(qa, :blank)
      assert flow.key == "qa-2"
    end

    test "RE431 4. add_flow/2 :blank falls back to `flow` for a slugless name", ctx do
      {:ok, stage} = Relay.Boards.create_stage(ctx.board, %{name: "!!!", category: :in_progress})

      assert {:ok, flow} = Flows.add_flow(stage, :blank)
      assert flow.key == "flow"
    end

    test "RE431 5. add_flow/2 refuses a key that isn't in the default library", ctx do
      before = flow_count(ctx.board)

      assert {:error, :not_a_default} = Flows.add_flow(ctx.stages["Deploy"], {:default, "nope"})
      assert flow_count(ctx.board) == before
    end

    test "RE431 6. add_flow/2 refuses an occupied stage with the error on stage_id", ctx do
      assert {:error, cs} = Flows.add_flow(ctx.stages["Plan"], :blank)
      assert "stage already has flow `plan`" in errors_on(cs).stage_id
    end

    test "RE431 7. copy_key/2 previews exactly the key copy_flow/2 gives", ctx do
      {:ok, qa} = Relay.Boards.create_stage(ctx.board, %{name: "QA", category: :in_progress})
      assert Flows.copy_key(ctx.code_flow, qa) == "code-qa"

      {:ok, _} = Flows.create_flow(ctx.board, one_stage_attrs(ctx.stages["Deploy"].id, %{key: "code-qa"}))
      assert Flows.copy_key(ctx.code_flow, qa) == "code-qa-2"

      assert {:ok, copy} = Flows.copy_flow(ctx.code_flow, qa)
      assert copy.key == "code-qa-2"
    end

    test "28. upsert_from_document/3 resolves the trigger stage (legacy triggers too)", ctx do
      doc =
        ctx.board
        |> Flows.get_flow_with_stages("code")
        |> Relay.Flows.Document.encode()
        |> Map.put("trigger", %{"pulls_from" => "X", "works_in" => "Code", "lands_on" => "Y"})

      assert {:ok, :updated, flow} = Flows.upsert_from_document(ctx.board, "code", doc)
      assert flow.stage_id == ctx.stages["Code"].id

      new_doc = %{"key" => "ship", "isolation" => "shared_clean", "edges" => [%{"from" => "start", "to" => "done"}]}

      assert {:error, {:unknown_stages, ["Nope"]}} =
               Flows.upsert_from_document(ctx.board, "ship", Map.put(new_doc, "trigger", %{"stage" => "Nope"}))

      assert {:error, {:invalid, cs}} = Flows.upsert_from_document(ctx.board, "ship", new_doc)
      assert "can't be blank" in errors_on(cs).stage_id
    end
  end
end
