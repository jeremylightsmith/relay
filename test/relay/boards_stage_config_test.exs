defmodule Relay.BoardsStageConfigTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Repo
  alias Schemas.CardOwner

  defp seeded_board do
    Boards.get_or_create_default_board(insert(:user))
  end

  # Seeded main-stage order: Backlog, Next up | Spec, Plan | Code, Review, Deploy | Done
  defp main_names(board) do
    board
    |> Boards.list_stages()
    |> Enum.filter(&is_nil(&1.parent_id))
    |> Enum.map(& &1.name)
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  defp categories(board) do
    board
    |> Boards.list_stages()
    |> Enum.filter(&is_nil(&1.parent_id))
    |> Enum.map(& &1.category)
  end

  describe "update_stage/2" do
    test "persists name, description, and type" do
      board = seeded_board()
      stage = stage_named(board, "Backlog")

      assert {:ok, updated} =
               Boards.update_stage(stage, %{
                 name: "Inbox",
                 description: "Raw ideas land here",
                 type: :work
               })

      assert updated.name == "Inbox"

      reloaded = Boards.get_stage(board, stage.id)
      assert reloaded.name == "Inbox"
      assert reloaded.description == "Raw ideas land here"
      assert reloaded.type == :work
    end

    test "rejects a blank name and persists nothing" do
      board = seeded_board()
      stage = stage_named(board, "Backlog")

      assert {:error, %Ecto.Changeset{}} = Boards.update_stage(stage, %{name: ""})
      assert Boards.get_stage(board, stage.id).name == "Backlog"
    end

    test "changing the stage type never touches card owner rows" do
      board = seeded_board()
      stage = stage_named(board, "Code")
      card = insert(:card, stage: stage)
      human = insert(:user)
      owner_row = insert(:card_owner, card: card, user: human)

      assert {:ok, %{type: :review}} = Boards.update_stage(stage, %{type: :review})

      assert [%CardOwner{} = row] = Repo.all(CardOwner)
      assert row.id == owner_row.id
      assert row.actor_type == :user
      assert row.user_id == human.id
    end
  end

  describe "reorder_stage/2" do
    test ":up swaps with the stage above within a category" do
      board = seeded_board()

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Plan"), :up)
      assert moved.category == :planning
      assert main_names(board) == ["Backlog", "Next up", "Plan", "Spec", "Code", "Review", "Deploy", "Done"]
    end

    test ":down across a boundary adopts the next category and leaves the neighbour untouched" do
      board = seeded_board()
      spec = stage_named(board, "Spec")

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Next up"), :down)

      # "Next up" alone crosses the band, landing at the TOP of Planning: the flat
      # board order is unchanged. Spec — already planning — stays put.
      assert moved.category == :planning
      assert Boards.get_stage(board, spec.id).category == :planning
      assert main_names(board) == ["Backlog", "Next up", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]

      assert categories(board) ==
               [:unstarted, :planning, :planning, :planning, :in_progress, :in_progress, :in_progress, :complete]
    end

    test ":up across a boundary adopts the previous category and leaves the neighbour untouched" do
      board = seeded_board()
      next_up = stage_named(board, "Next up")

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Spec"), :up)

      # Spec lands at the BOTTOM of Unstarted; "Next up" keeps its category.
      assert moved.category == :unstarted
      assert Boards.get_stage(board, next_up.id).category == :unstarted
      assert main_names(board) == ["Backlog", "Next up", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test ":down into an empty adjacent category lands there instead of skipping past it" do
      board = seeded_board()
      {:ok, _} = Boards.delete_stage(stage_named(board, "Plan"))
      {:ok, _} = Boards.delete_stage(stage_named(board, "Spec"))

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Next up"), :down)
      assert moved.category == :planning
      assert main_names(board) == ["Backlog", "Next up", "Code", "Review", "Deploy", "Done"]

      # A second :down crosses on into In progress, again without touching Code.
      assert {:ok, again} = Boards.reorder_stage(Boards.get_stage(board, moved.id), :down)
      assert again.category == :in_progress
      assert Boards.get_stage(board, stage_named(board, "Code").id).category == :in_progress
    end

    test ":up into an empty adjacent category lands there instead of skipping past it" do
      board = seeded_board()
      {:ok, _} = Boards.delete_stage(stage_named(board, "Plan"))
      {:ok, _} = Boards.delete_stage(stage_named(board, "Spec"))

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Code"), :up)
      assert moved.category == :planning
      assert main_names(board) == ["Backlog", "Next up", "Code", "Review", "Deploy", "Done"]
    end

    test "the first and last categories no-op at the board's edges" do
      board = seeded_board()

      assert {:ok, %{position: 1, category: :unstarted}} =
               Boards.reorder_stage(stage_named(board, "Backlog"), :up)

      assert {:ok, %{name: "Done", category: :complete}} =
               Boards.reorder_stage(stage_named(board, "Done"), :down)

      assert main_names(board) == ["Backlog", "Next up", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "swapping skips over sub-lane children" do
      board = seeded_board()
      {:ok, _child} = Boards.enable_lane(stage_named(board, "Code"), :review)

      assert {:ok, _moved} = Boards.reorder_stage(stage_named(board, "Review"), :up)
      assert main_names(board) == ["Backlog", "Next up", "Spec", "Plan", "Review", "Code", "Deploy", "Done"]
    end

    test "reordering never touches card owners and keeps main positions contiguous" do
      board = seeded_board()
      code = stage_named(board, "Code")
      card = insert(:card, stage: code)
      owner_row = insert(:card_owner, card: card, user: insert(:user))

      {:ok, _} = Boards.reorder_stage(stage_named(board, "Spec"), :down)
      {:ok, _} = Boards.reorder_stage(Boards.get_stage(board, code.id), :up)

      assert [%CardOwner{} = row] = Repo.all(CardOwner)
      assert row.id == owner_row.id

      positions =
        board |> Boards.list_stages() |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.map(& &1.position)

      assert positions == Enum.to_list(1..8)
    end
  end

  describe "create_stage/2" do
    test "appends a default stage at the end of the category" do
      board = seeded_board()

      assert {:ok, stage} = Boards.create_stage(board, :unstarted)
      assert stage.name == "New stage"
      assert stage.type == :queue
      refute Flows.ai_stage?(stage)
      assert stage.category == :unstarted
      assert is_nil(stage.parent_id)

      assert main_names(board) ==
               ["Backlog", "Next up", "New stage", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "appends to a category that has become empty" do
      board = seeded_board()
      {:ok, _} = Boards.delete_stage(stage_named(board, "Done"))

      assert {:ok, stage} = Boards.create_stage(board, :complete)
      assert stage.category == :complete
      assert stage.type == :done

      assert main_names(board) ==
               ["Backlog", "Next up", "Spec", "Plan", "Code", "Review", "Deploy", "New stage"]
    end

    test "keeps positions unique across mains and sub-lane children" do
      board = seeded_board()
      {:ok, _child} = Boards.enable_lane(stage_named(board, "Code"), :done)

      assert {:ok, _stage} = Boards.create_stage(board, :in_progress)

      positions = board |> Boards.list_stages() |> Enum.map(& &1.position)
      assert positions == Enum.uniq(positions)
    end
  end

  describe "delete_stage/1" do
    test "deletes an empty stage together with its sub-lane children" do
      board = seeded_board()
      code = stage_named(board, "Code")
      {:ok, child} = Boards.enable_lane(code, :review)

      assert {:ok, _deleted} = Boards.delete_stage(code)
      assert Boards.get_stage(board, code.id) == nil
      assert Boards.get_stage(board, child.id) == nil
    end

    test "refuses when the main lane holds cards" do
      board = seeded_board()
      code = stage_named(board, "Code")
      insert(:card, stage: code)

      assert {:error, {:not_empty, %{live: 1, archived: 0}}} = Boards.delete_stage(code)
      assert Boards.get_stage(board, code.id)
    end

    test "refuses when a sub-lane holds cards" do
      board = seeded_board()
      code = stage_named(board, "Code")
      {:ok, child} = Boards.enable_lane(code, :review)
      insert(:card, stage: child)

      assert {:error, {:not_empty, %{live: 1, archived: 0}}} = Boards.delete_stage(code)
      assert Boards.get_stage(board, code.id)
      assert Boards.get_stage(board, child.id)
    end

    test "refuses to delete the board's only main stage" do
      board = insert(:board)
      only = insert(:stage, board: board, position: 1)

      assert {:error, :last_stage} = Boards.delete_stage(only)
    end
  end

  describe "create_stage/2 with attrs (RE384)" do
    test "inserts after an anchor, adopting its category" do
      board = seeded_board()
      spec = stage_named(board, "Spec")

      assert {:ok, stage} = Boards.create_stage(board, %{name: "Triage", after: spec, type: :queue})
      assert stage.category == :planning
      assert stage.type == :queue

      assert main_names(board) ==
               ["Backlog", "Next up", "Spec", "Triage", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "inserts before an anchor with the category's default type" do
      board = seeded_board()

      assert {:ok, stage} = Boards.create_stage(board, %{name: "Inbox", before: stage_named(board, "Backlog")})
      assert stage.category == :unstarted
      assert stage.type == :queue
      assert hd(main_names(board)) == "Inbox"
    end

    test "without an anchor appends to its category with the given settings" do
      board = seeded_board()

      assert {:ok, stage} =
               Boards.create_stage(board, %{
                 name: "QA",
                 category: :in_progress,
                 description: "d",
                 wip_limit: 2,
                 collapsed_by_default: true
               })

      assert stage.type == :work
      refute Flows.ai_stage?(stage)
      assert stage.wip_limit == 2
      assert stage.description == "d"
      assert stage.collapsed_by_default == true

      assert main_names(board) ==
               ["Backlog", "Next up", "Spec", "Plan", "Code", "Review", "Deploy", "QA", "Done"]
    end

    test "a category that differs from the anchor's is a changeset error" do
      board = seeded_board()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Boards.create_stage(board, %{name: "X", category: :complete, after: stage_named(board, "Spec")})

      assert "must match the anchor stage's category" in errors_on(changeset).category
      assert length(main_names(board)) == 8
    end

    test "a string category equal to the anchor's is accepted" do
      board = seeded_board()

      assert {:ok, %{category: :planning}} =
               Boards.create_stage(board, %{name: "X", category: "planning", after: stage_named(board, "Spec")})
    end

    test "invalid attrs insert nothing and broadcast nothing" do
      board = seeded_board()
      :ok = Relay.Events.subscribe(board.id)
      before = length(Boards.list_stages(board))

      assert {:error, blank} = Boards.create_stage(board, %{name: "  ", category: :planning})
      assert errors_on(blank)[:name]

      assert {:error, no_category} = Boards.create_stage(board, %{name: "X"})
      assert "can't be blank" in errors_on(no_category).category

      assert {:error, bad_wip} = Boards.create_stage(board, %{name: "X", category: :planning, wip_limit: 0})
      assert errors_on(bad_wip)[:wip_limit]

      assert length(Boards.list_stages(board)) == before
      refute_receive {:stages_changed, _}
    end

    test "a substage or another board's stage is an invalid anchor" do
      board = seeded_board()
      other = Boards.get_or_create_default_board(insert(:user))
      before = length(Boards.list_stages(board))

      assert {:error, :invalid_anchor} =
               Boards.create_stage(board, %{name: "X", after: stage_named(board, "Spec:Review")})

      assert {:error, :invalid_anchor} =
               Boards.create_stage(board, %{name: "X", after: stage_named(other, "Spec")})

      assert length(Boards.list_stages(board)) == before
    end

    test "keeps positions unique with substages above every main stage" do
      board = seeded_board()
      assert {:ok, _} = Boards.create_stage(board, %{name: "Y", after: stage_named(board, "Plan")})

      stages = Boards.list_stages(board)
      positions = Enum.map(stages, & &1.position)
      assert positions == Enum.uniq(positions)

      {subs, mains} = Enum.split_with(stages, & &1.parent_id)
      assert Enum.min(Enum.map(subs, & &1.position)) > Enum.max(Enum.map(mains, & &1.position))
    end
  end

  describe "place_stage/2 (RE384)" do
    test "moves a stage before an anchor, adopting its category but not changing its type" do
      board = seeded_board()
      board_id = board.id
      :ok = Relay.Events.subscribe(board_id)

      assert {:ok, moved} = Boards.place_stage(stage_named(board, "Deploy"), before: stage_named(board, "Backlog"))
      assert moved.category == :unstarted
      assert moved.type == :work
      assert Enum.take(main_names(board), 2) == ["Deploy", "Backlog"]

      positions =
        board |> Boards.list_stages() |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.map(& &1.position)

      assert positions == Enum.to_list(1..8)
      assert_receive {:stages_changed, ^board_id}
    end

    test "moves a stage after an anchor in another category" do
      board = seeded_board()

      assert {:ok, moved} = Boards.place_stage(stage_named(board, "Backlog"), after: stage_named(board, "Plan"))
      assert moved.category == :planning
      assert main_names(board) == ["Next up", "Spec", "Plan", "Backlog", "Code", "Review", "Deploy", "Done"]
    end

    test "placing a stage where it already is writes and broadcasts nothing" do
      board = seeded_board()
      plan = stage_named(board, "Plan")
      :ok = Relay.Events.subscribe(board.id)

      assert {:ok, ^plan} = Boards.place_stage(plan, after: stage_named(board, "Spec"))
      refute_receive {:stages_changed, _}
    end

    test "refuses itself, a substage or another board's stage as anchor" do
      board = seeded_board()
      other = Boards.get_or_create_default_board(insert(:user))
      spec = stage_named(board, "Spec")

      assert {:error, :invalid_anchor} = Boards.place_stage(spec, before: spec)
      assert {:error, :invalid_anchor} = Boards.place_stage(spec, after: stage_named(board, "Spec:Done"))
      assert {:error, :invalid_anchor} = Boards.place_stage(spec, after: stage_named(other, "Plan"))
    end

    test "refuses to move a substage" do
      board = seeded_board()

      assert {:error, :not_a_main_stage} =
               Boards.place_stage(stage_named(board, "Spec:Done"), before: stage_named(board, "Backlog"))
    end
  end

  describe "delete_stage/1 guard rails (RE384)" do
    defp archived_card(stage), do: insert(:card, stage: stage, archived_at: DateTime.utc_now(:second))

    # Each enabled flow needs its own pulls-from stage (one enabled flow per pulls-from stage).
    defp enabled_flow(board, key, field, stage, pulls_from \\ "Backlog") do
      triggers =
        Map.put(
          %{
            pulls_from_stage_id: stage_named(board, pulls_from).id,
            works_in_stage_id: stage_named(board, "Code").id,
            lands_on_stage_id: stage_named(board, "Review").id
          },
          field,
          stage.id
        )

      insert(:flow, Map.merge(%{board: board, key: key, enabled: true}, triggers))
    end

    test "an empty stage with no enabled flows is deleted" do
      board = seeded_board()
      deploy = stage_named(board, "Deploy")

      assert {:ok, _} = Boards.delete_stage(deploy)
      assert Boards.get_stage(board, deploy.id) == nil
    end

    test "archived cards count" do
      board = seeded_board()
      code = stage_named(board, "Code")
      archived_card(code)

      assert {:error, {:not_empty, %{live: 0, archived: 1}}} = Boards.delete_stage(code)
    end

    test "counts live and archived cards across the stage and its substages" do
      board = seeded_board()
      code = stage_named(board, "Code")
      {:ok, review} = Boards.enable_lane(code, :review)
      insert(:card, stage: code)
      insert(:card, stage: code)
      archived_card(review)

      assert {:error, {:not_empty, %{live: 2, archived: 1}}} = Boards.delete_stage(code)
    end

    test "refuses a stage an enabled flow works in" do
      board = seeded_board()
      deploy = stage_named(board, "Deploy")
      flow = enabled_flow(board, "ship", :works_in_stage_id, deploy)

      assert {:error, {:in_use_by_flow, ["ship"]}} = Boards.delete_stage(deploy)
      assert Repo.reload!(flow).works_in_stage_id == deploy.id
    end

    test "refuses a stage whose substage enabled flows land on, naming them sorted" do
      board = seeded_board()
      plan_done = stage_named(board, "Plan:Done")
      enabled_flow(board, "zeta", :lands_on_stage_id, plan_done)
      enabled_flow(board, "alpha", :lands_on_stage_id, plan_done, "Next up")

      assert {:error, {:in_use_by_flow, ["alpha", "zeta"]}} = Boards.delete_stage(stage_named(board, "Plan"))
    end

    test "a disabled flow does not block the delete and its trigger is nilified" do
      board = seeded_board()
      deploy = stage_named(board, "Deploy")

      flow =
        insert(:flow,
          board: board,
          key: "idle",
          enabled: false,
          works_in_stage_id: deploy.id
        )

      assert {:ok, _} = Boards.delete_stage(deploy)
      assert Repo.reload!(flow).works_in_stage_id == nil
    end

    test "refuses the public intake stage" do
      board = seeded_board()
      deploy = stage_named(board, "Deploy")
      {:ok, _} = Boards.update_public_settings(board, %{public_intake_stage_id: deploy.id})

      assert {:error, :public_intake} = Boards.delete_stage(deploy)
    end

    test "a reject-to target may be deleted and the reference is nilified" do
      board = seeded_board()
      plan = stage_named(board, "Plan")
      review = stage_named(board, "Review")
      assert review.reject_to_stage_id == plan.id

      assert {:ok, _} = Boards.delete_stage(plan)
      assert Repo.reload!(review).reject_to_stage_id == nil
    end

    test "the last stage guard comes first" do
      board = insert(:board)
      only = insert(:stage, board: board, position: 1)
      archived_card(only)

      assert {:error, :last_stage} = Boards.delete_stage(only)
    end

    test "refuses a substage" do
      board = seeded_board()
      assert {:error, :not_a_main_stage} = Boards.delete_stage(stage_named(board, "Spec:Review"))
    end
  end

  describe "stage_refusal_message/1 (RE384)" do
    test "renders every refusal reason" do
      assert Boards.stage_refusal_message(:last_stage) == "A board needs at least one stage."

      assert Boards.stage_refusal_message({:not_empty, %{live: 2, archived: 1}}) ==
               "That stage still holds 2 live and 1 archived card(s) — move them out first."

      assert Boards.stage_refusal_message(:not_empty) == "That lane still has cards — move them out first."

      assert Boards.stage_refusal_message({:in_use_by_flow, ["code", "plan"]}) ==
               "Flow(s) code, plan use this stage — disable or re-point them first."

      assert Boards.stage_refusal_message(:public_intake) ==
               "This is the public intake stage — pick another in Public settings first."

      assert Boards.stage_refusal_message(:invalid_anchor) ==
               "before/after must name another main stage on this board."

      assert Boards.stage_refusal_message(:not_a_main_stage) ==
               "That is a substage — address its main stage instead (substages follow their parent)."
    end
  end

  describe "broadcasts" do
    test "each successful mutation broadcasts {:stages_changed, board_id}" do
      board = seeded_board()
      board_id = board.id
      :ok = Relay.Events.subscribe(board_id)
      backlog = stage_named(board, "Backlog")

      {:ok, _} = Boards.update_stage(backlog, %{name: "Inbox"})
      assert_receive {:stages_changed, ^board_id}

      {:ok, _} = Boards.reorder_stage(Boards.get_stage(board, backlog.id), :down)
      assert_receive {:stages_changed, ^board_id}

      {:ok, created} = Boards.create_stage(board, :complete)
      assert_receive {:stages_changed, ^board_id}

      {:ok, _} = Boards.delete_stage(created)
      assert_receive {:stages_changed, ^board_id}
    end

    test "guarded failures and edge no-ops stay silent" do
      board = seeded_board()
      :ok = Relay.Events.subscribe(board.id)
      backlog = stage_named(board, "Backlog")
      insert(:card, stage: backlog)

      {:error, {:not_empty, _counts}} = Boards.delete_stage(backlog)
      {:error, %Ecto.Changeset{}} = Boards.update_stage(backlog, %{name: ""})
      {:ok, _} = Boards.reorder_stage(backlog, :up)

      refute_receive {:stages_changed, _board_id}
    end

    test "delete guard refusals stay silent (RE384)" do
      board = seeded_board()
      :ok = Relay.Events.subscribe(board.id)
      code = stage_named(board, "Code")
      insert(:card, stage: code, archived_at: DateTime.utc_now(:second))
      deploy = stage_named(board, "Deploy")

      insert(:flow,
        board: board,
        key: "ship",
        enabled: true,
        pulls_from_stage_id: stage_named(board, "Backlog").id,
        works_in_stage_id: deploy.id,
        lands_on_stage_id: stage_named(board, "Done").id
      )

      {:ok, _} = Boards.update_public_settings(board, %{public_intake_stage_id: stage_named(board, "Next up").id})

      {:error, {:not_empty, _}} = Boards.delete_stage(code)
      {:error, {:in_use_by_flow, ["ship"]}} = Boards.delete_stage(deploy)
      {:error, :public_intake} = Boards.delete_stage(stage_named(board, "Next up"))

      refute_receive {:stages_changed, _board_id}
    end
  end

  describe "update_stage/2 rename cascade (RE385)" do
    defp children_of(board, parent) do
      board
      |> Boards.list_stages()
      |> Enum.filter(&(&1.parent_id == parent.id))
      |> Enum.sort_by(& &1.type)
    end

    test "renaming a main stage renames its Review and Done substages" do
      board = seeded_board()
      spec = stage_named(board, "Spec")
      review = stage_named(board, "Spec:Review")
      done = stage_named(board, "Spec:Done")

      assert {:ok, %Schemas.Stage{name: "Specify"}} = Boards.update_stage(spec, %{name: "Specify"})

      reloaded_review = Boards.get_stage(board, review.id)
      reloaded_done = Boards.get_stage(board, done.id)
      assert reloaded_review.name == "Specify:Review"
      assert reloaded_review.type == :review
      assert reloaded_done.name == "Specify:Done"
      assert reloaded_done.type == :done
    end

    test "a stage with only a Done substage renames just that one" do
      board = seeded_board()
      plan = stage_named(board, "Plan")

      assert {:ok, _} = Boards.update_stage(plan, %{name: "Design"})

      assert [%{name: "Design:Done", type: :done}] = children_of(board, plan)
      refute Enum.any?(Boards.list_stages(board), &(&1.name == "Design:Review"))
    end

    test "renaming a substage directly cascades nowhere" do
      board = seeded_board()
      review = stage_named(board, "Spec:Review")

      assert {:ok, %{name: "Odd"}} = Boards.update_stage(review, %{name: "Odd"})

      assert Boards.get_stage(board, stage_named(board, "Spec").id).name == "Spec"
      assert Boards.get_stage(board, stage_named(board, "Spec:Done").id).name == "Spec:Done"
    end

    test "an update without a name change cascades nothing" do
      board = seeded_board()
      spec = stage_named(board, "Spec")

      assert {:ok, _} = Boards.update_stage(spec, %{description: "write it down", wip_limit: 2})

      for {name, id} <- [
            {"Spec:Review", stage_named(board, "Spec:Review").id},
            {"Spec:Done", stage_named(board, "Spec:Done").id}
          ] do
        child = Boards.get_stage(board, id)
        assert child.name == name
        assert child.description == nil
        assert child.wip_limit == nil
      end
    end

    test "an invalid rename changes nothing and broadcasts nothing" do
      board = seeded_board()
      :ok = Relay.Events.subscribe(board.id)
      spec = stage_named(board, "Spec")

      assert {:error, %Ecto.Changeset{}} = Boards.update_stage(spec, %{name: ""})

      assert Boards.get_stage(board, spec.id).name == "Spec"
      assert board |> children_of(spec) |> Enum.map(& &1.name) |> Enum.sort() == ["Spec:Done", "Spec:Review"]
      refute_receive {:stages_changed, _board_id}
    end

    test "a cascading rename broadcasts exactly once" do
      board = seeded_board()
      board_id = board.id
      :ok = Relay.Events.subscribe(board_id)

      assert {:ok, _} = Boards.update_stage(stage_named(board, "Spec"), %{name: "Specify"})

      assert_receive {:stages_changed, ^board_id}
      refute_receive {:stages_changed, ^board_id}, 100
    end
  end
end
