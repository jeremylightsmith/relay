defmodule Relay.CardsDependenciesTest do
  use Relay.DataCase, async: true

  import Ecto.Query

  alias Relay.Cards
  alias Relay.Events
  alias Schemas.CardDependency

  setup do
    board = insert(:board, key: "RE")
    todo = insert(:stage, board: board, name: "Next up", category: :unstarted, position: 1)
    done = insert(:stage, board: board, name: "Done", category: :complete, position: 9)

    a = insert(:card, stage: todo, ref_number: 1, title: "A")
    b = insert(:card, stage: todo, ref_number: 2, title: "B")
    c = insert(:card, stage: todo, ref_number: 3, title: "C")

    %{board: board, todo: todo, done: done, a: a, b: b, c: c}
  end

  defp stages(board), do: Relay.Boards.list_stages(board)

  defp blocker_ids(card),
    do: Repo.all(from d in CardDependency, where: d.card_id == ^card.id, select: d.depends_on_card_id)

  describe "set_dependencies/4" do
    test "writes the named blockers", ctx do
      assert {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "RE3"])
      assert Enum.sort(blocker_ids(ctx.a)) == Enum.sort([ctx.b.id, ctx.c.id])
    end

    test "is a FULL REPLACE, and [] clears", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "RE3"])
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      assert blocker_ids(ctx.a) == [ctx.b.id]

      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, [])
      assert blocker_ids(ctx.a) == []
    end

    test "duplicate refs collapse to one row", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "RE2"])
      assert blocker_ids(ctx.a) == [ctx.b.id]
    end

    test "an unknown ref rejects the WHOLE call — the valid ref is not applied either", ctx do
      assert {:error, {:unknown_refs, ["ZZ999"]}} =
               Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "ZZ999"])

      assert blocker_ids(ctx.a) == []
    end

    test "a cross-board ref is simply unknown", ctx do
      other_board = insert(:board, key: "XX")
      other_stage = insert(:stage, board: other_board, position: 1)
      insert(:card, stage: other_stage, ref_number: 7)

      assert {:error, {:unknown_refs, ["XX7"]}} = Cards.set_dependencies(ctx.board, ctx.a, ["XX7"])
    end

    test "self-reference is refused as a two-step cycle", ctx do
      assert {:error, {:dependency_cycle, ["RE1", "RE1"]}} =
               Cards.set_dependencies(ctx.board, ctx.a, ["RE1"])
    end

    test "a 2-cycle is refused and names the path it would close", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])

      assert {:error, {:dependency_cycle, ["RE2", "RE1", "RE2"]}} =
               Cards.set_dependencies(ctx.board, ctx.b, ["RE1"])

      assert blocker_ids(ctx.b) == []
    end

    test "a 3-cycle is refused", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.b, ["RE3"])

      assert {:error, {:dependency_cycle, ["RE3", "RE1", "RE2", "RE3"]}} =
               Cards.set_dependencies(ctx.board, ctx.c, ["RE1"])
    end

    test "a real change logs :dependencies_changed with added/removed refs and broadcasts", ctx do
      Events.subscribe(ctx.board.id)

      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      assert_receive {:card_upserted, _}

      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE3"])
      assert_receive {:card_upserted, _}

      entries =
        ctx.a
        |> Relay.Activity.list_activity()
        |> Enum.filter(&(&1.type == :dependencies_changed))
        |> Enum.map(& &1.meta)

      assert %{"added" => ["RE3"], "removed" => ["RE2"]} in entries
      assert %{"added" => ["RE2"], "removed" => []} in entries
    end

    test "a no-op re-set writes, logs and broadcasts nothing", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      Events.subscribe(ctx.board.id)

      assert {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      refute_receive {:card_upserted, _}

      assert ctx.a
             |> Relay.Activity.list_activity()
             |> Enum.count(&(&1.type == :dependencies_changed)) == 1
    end
  end

  describe "unknown_refs/2" do
    test "names the refs resolving to no card on the board, in the order given", ctx do
      assert Cards.unknown_refs(ctx.board, ["RE2", "ZZ999", "RE3", "RE404"]) == ["ZZ999", "RE404"]
    end

    test "is empty when every ref resolves, and duplicates collapse", ctx do
      assert Cards.unknown_refs(ctx.board, ["RE2", "RE2", "RE3"]) == []
      assert Cards.unknown_refs(ctx.board, []) == []
    end

    test "agrees with what set_dependencies/4 refuses", ctx do
      refs = ["RE2", "ZZ999"]

      assert Cards.unknown_refs(ctx.board, refs) == ["ZZ999"]
      assert Cards.set_dependencies(ctx.board, ctx.a, refs) == {:error, {:unknown_refs, ["ZZ999"]}}
    end
  end

  describe "unmet_dependencies/2" do
    test "a blocker in a :complete top-level stage is satisfied REGARDLESS of its status", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      assert Cards.unmet_dependencies(ctx.board, stages(ctx.board)) == %{ctx.a.id => [ctx.b.id]}

      for status <- [:ready, :working, :failed, :needs_input] do
        {:ok, _} =
          ctx.b
          |> Ecto.Changeset.change(stage_id: ctx.done.id, status: status)
          |> Repo.update()

        assert Cards.unmet_dependencies(ctx.board, stages(ctx.board)) == %{}
      end
    end

    test "an archived blocker never blocks", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])

      {:ok, _} =
        ctx.b |> Ecto.Changeset.change(archived_at: DateTime.truncate(DateTime.utc_now(), :second)) |> Repo.update()

      assert Cards.unmet_dependencies(ctx.board, stages(ctx.board)) == %{}
    end

    test "cards with no unmet blocker are absent from the map", ctx do
      assert Cards.unmet_dependencies(ctx.board, stages(ctx.board)) == %{}
    end
  end

  describe "list_scheduler_cards/2 (RE402)" do
    # a (RE1, :ready, agent + user owner) blocked by b and c; b (RE2) owned by a user only.
    setup ctx do
      {:ok, a} = ctx.a |> Ecto.Changeset.change(status: :ready) |> Repo.update()
      insert(:card_owner, card: a)
      insert(:card_owner, card: a, user: insert(:user))
      insert(:card_owner, card: ctx.b, user: insert(:user))
      {:ok, _} = Cards.set_dependencies(ctx.board, a, ["RE2", "RE3"])
      %{a: a}
    end

    defp done_ids(board), do: Relay.Boards.top_level_done_stage_ids(stages(board))

    defp scheduler_cards(board), do: Map.new(Cards.list_scheduler_cards(board.id, done_ids(board)), &{&1.id, &1})

    test "projects each card to the snapshot card map", ctx do
      cards = scheduler_cards(ctx.board)

      assert cards[ctx.a.id] == %{
               id: ctx.a.id,
               ref: "RE1",
               stage_id: ctx.todo.id,
               status: :ready,
               active_owner: :ai,
               position: ctx.a.position,
               blocked_by: Enum.sort([ctx.b.id, ctx.c.id])
             }

      assert %{ref: "RE2", active_owner: :human, blocked_by: []} = cards[ctx.b.id]
    end

    test "is ordered stage, position, id like list_cards/1", ctx do
      ids = Enum.map(Cards.list_scheduler_cards(ctx.board.id, done_ids(ctx.board)), & &1.id)
      assert ids == Enum.map(Cards.list_cards(ctx.board), & &1.id)
    end

    test "an unowned card has no active owner", ctx do
      assert scheduler_cards(ctx.board)[ctx.c.id].active_owner == nil
    end

    test "a blocker in a top-level :complete stage no longer blocks", ctx do
      {:ok, _} = ctx.b |> Ecto.Changeset.change(stage_id: ctx.done.id) |> Repo.update()
      {:ok, _} = ctx.c |> Ecto.Changeset.change(stage_id: ctx.done.id) |> Repo.update()
      assert scheduler_cards(ctx.board)[ctx.a.id].blocked_by == []
    end

    test "an archived blocker never blocks", ctx do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {:ok, _} = ctx.b |> Ecto.Changeset.change(archived_at: now) |> Repo.update()
      {:ok, _} = ctx.c |> Ecto.Changeset.change(archived_at: now) |> Repo.update()
      assert scheduler_cards(ctx.board)[ctx.a.id].blocked_by == []
    end

    test "an archived card is absent", ctx do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {:ok, _} = ctx.c |> Ecto.Changeset.change(archived_at: now) |> Repo.update()
      refute Map.has_key?(scheduler_cards(ctx.board), ctx.c.id)
    end

    test "agrees with unmet_dependencies/2 for every card (one predicate, two readers)", ctx do
      unmet = Cards.unmet_dependencies(ctx.board, stages(ctx.board))

      for card <- Cards.list_scheduler_cards(ctx.board.id, done_ids(ctx.board)) do
        assert unmet |> Map.get(card.id, []) |> Enum.sort() == card.blocked_by
      end
    end

    test "is one query", ctx do
      done_ids = done_ids(ctx.board)
      {_cards, count} = count_repo_queries(self(), fn -> Cards.list_scheduler_cards(ctx.board.id, done_ids) end)
      assert count == 1
    end
  end

  describe "list_dependencies/2 and list_dependents/2" do
    test "both directions, ref-ordered, with the satisfied flag", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE3", "RE2"])
      {:ok, _} = ctx.c |> Ecto.Changeset.change(stage_id: ctx.done.id) |> Repo.update()

      assert [
               %{ref: "RE2", title: "B", satisfied?: false},
               %{ref: "RE3", title: "C", satisfied?: true}
             ] = Cards.list_dependencies(ctx.board, ctx.a)

      assert [%{ref: "RE1", title: "A"}] = Cards.list_dependents(ctx.board, ctx.b)
      assert Cards.list_dependents(ctx.board, ctx.a) == []
    end
  end

  describe "archive_card/2" do
    test "deletes the rows pointing AT the card and leaves its own outgoing rows", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.b, ["RE3"])

      {:ok, _} = Cards.archive_card(ctx.b)

      assert blocker_ids(ctx.a) == []
      assert blocker_ids(ctx.b) == [ctx.c.id]
    end

    test "unarchiving does NOT restore the deleted incoming rows", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      {:ok, archived} = Cards.archive_card(ctx.b)
      {:ok, _} = Cards.unarchive_card(archived)

      assert blocker_ids(ctx.a) == []
    end
  end

  describe "dependency_error_message/1" do
    test "renders both refusals" do
      assert Cards.dependency_error_message({:unknown_refs, ["RE99", "RE100"]}) ==
               "this board has no card with ref: RE99, RE100"

      assert Cards.dependency_error_message({:dependency_cycle, ["RE93", "RE94", "RE93"]}) ==
               "that would create a dependency cycle: RE93 → RE94 → RE93"
    end
  end
end
