defmodule Hamaca.CardsTargetBranchTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Cards
  alias Hamaca.Events
  alias Schemas.Card

  setup do
    board = insert(:board, key: "RE")
    stage = insert(:stage, board: board, name: "Next up", category: :unstarted, position: 1)
    insert(:stage, board: board, name: "Done", category: :complete, position: 9)

    %{board: board, stage: stage}
  end

  defp create!(stage, title, extra \\ %{}) do
    {:ok, card} = Cards.create_card(stage, Map.put(extra, "title", title), :agent)
    card
  end

  # Writes an override straight to the row, so a scenario's precondition does not depend on
  # set_target_branch/3 (which the scenarios test separately).
  defp put_override!(card, branch), do: card |> Ecto.Changeset.change(target_branch: branch) |> Repo.update!()

  describe "effective_target/2" do
    test "a card with no override resolves to the board default", %{board: board} do
      assert board.target_branch == "main"
      assert Cards.effective_target(board, %Card{target_branch: nil}) == "main"
    end

    test "a card's override wins over the board default", %{board: board} do
      assert Cards.effective_target(board, %Card{target_branch: "exp/flows"}) == "exp/flows"
    end
  end

  describe "set_target_branch/3" do
    test "sets the override on an idle card, clears the inherited-from pointer, logs and broadcasts", ctx do
      spawner = create!(ctx.stage, "spawner")
      card = ctx.stage |> create!("card") |> Ecto.Changeset.change(target_inherited_from_id: spawner.id) |> Repo.update!()
      Events.subscribe(ctx.board.id)

      assert {:ok, %Card{} = updated} = Cards.set_target_branch(card, "exp/flows", :agent)
      assert updated.target_branch == "exp/flows"
      assert updated.target_inherited_from_id == nil
      assert Repo.reload!(card).target_branch == "exp/flows"

      card_id = card.id
      assert_receive {:card_upserted, %Card{id: ^card_id}}

      metas =
        card
        |> Hamaca.Activity.list_activity()
        |> Enum.filter(&(&1.type == :target_changed))
        |> Enum.map(& &1.meta)

      assert metas == [%{"from" => nil, "to" => "exp/flows"}]
    end

    test "refuses while the card has a running run", ctx do
      card = put_override!(create!(ctx.stage, "card"), "exp/flows")
      insert(:run, card: card, status: :running)

      assert Cards.set_target_branch(card, "exp/other", :agent) == {:error, :run_active}
      assert Repo.reload!(card).target_branch == "exp/flows"
    end

    test "refuses while the card has a parked run", ctx do
      card = put_override!(create!(ctx.stage, "card"), "exp/flows")
      insert(:run, card: card, status: :parked)

      assert Cards.set_target_branch(card, "exp/other", :agent) == {:error, :run_active}
      assert Repo.reload!(card).target_branch == "exp/flows"
    end

    test "an invalid name is a changeset error", ctx do
      card = create!(ctx.stage, "card")

      assert {:error, %Ecto.Changeset{} = changeset} = Cards.set_target_branch(card, "a b", :agent)
      assert "is not a valid git branch name" in errors_on(changeset).target_branch
    end

    test "validation runs before the active-run check", ctx do
      card = create!(ctx.stage, "card")
      insert(:run, card: card, status: :running)

      assert {:error, %Ecto.Changeset{} = changeset} = Cards.set_target_branch(card, "a b", :agent)
      assert "is not a valid git branch name" in errors_on(changeset).target_branch
    end
  end

  describe "create_card/3 with spawned_from" do
    test "a child copies the spawner's override and remembers where it came from", ctx do
      a = put_override!(create!(ctx.stage, "A"), "exp/flows")
      ref_a = Cards.ref(ctx.board, a)

      assert {:ok, child} = Cards.create_card(ctx.stage, %{"title" => "child", "spawned_from" => ref_a}, :agent)
      assert child.target_branch == "exp/flows"
      assert child.target_inherited_from_id == a.id
      assert Cards.target_inherited_from_ref(ctx.board, child) == ref_a
    end

    test "a child of a spawner with no override copies its active run's snapshot", ctx do
      a = create!(ctx.stage, "A")
      insert(:run, card: a, status: :running, context: %{"target" => "exp/snap"})

      {:ok, child} =
        Cards.create_card(ctx.stage, %{spawned_from: Cards.ref(ctx.board, a), title: "child"}, :agent)

      assert child.target_branch == "exp/snap"
      assert child.target_inherited_from_id == a.id
    end

    test "a child of a spawner on the board default inherits nothing", ctx do
      a = create!(ctx.stage, "A")

      {:ok, child} =
        Cards.create_card(ctx.stage, %{"title" => "child", "spawned_from" => Cards.ref(ctx.board, a)}, :agent)

      assert child.target_branch == nil
      assert child.target_inherited_from_id == nil
    end

    test "a child of a spawner whose override equals the board default inherits nothing", ctx do
      a = put_override!(create!(ctx.stage, "A"), "main")

      {:ok, child} =
        Cards.create_card(ctx.stage, %{"title" => "child", "spawned_from" => Cards.ref(ctx.board, a)}, :agent)

      assert child.target_branch == nil
      assert child.target_inherited_from_id == nil
    end

    test "a spawner's active run snapshot wins over its override", ctx do
      a = put_override!(create!(ctx.stage, "A"), "exp/override")
      insert(:run, card: a, status: :running, context: %{"target" => "exp/snap"})

      {:ok, child} =
        Cards.create_card(ctx.stage, %{"title" => "child", "spawned_from" => Cards.ref(ctx.board, a)}, :agent)

      assert child.target_branch == "exp/snap"
      assert child.target_inherited_from_id == a.id
    end

    test "the copy is made once: a later change to the spawner does not follow", ctx do
      a = put_override!(create!(ctx.stage, "A"), "exp/flows")

      {:ok, child} =
        Cards.create_card(ctx.stage, %{"title" => "child", "spawned_from" => Cards.ref(ctx.board, a)}, :agent)

      {:ok, _a} = Cards.set_target_branch(a, "exp/v2", :agent)

      assert Repo.reload!(child).target_branch == "exp/flows"
    end

    test "an unknown spawned_from ref is refused before a ref number is allocated", ctx do
      seq_before = Repo.reload!(ctx.board).card_seq

      assert Cards.create_card(ctx.stage, %{"title" => "x", "spawned_from" => "RE9999"}, :agent) ==
               {:error, {:unknown_spawned_from, "RE9999"}}

      assert Repo.reload!(ctx.board).card_seq == seq_before
    end

    test "hard-deleting the spawner nils the child's inherited-from pointer", ctx do
      a = put_override!(create!(ctx.stage, "A"), "exp/flows")

      {:ok, child} =
        Cards.create_card(ctx.stage, %{"title" => "child", "spawned_from" => Cards.ref(ctx.board, a)}, :agent)

      assert child.target_inherited_from_id == a.id

      Repo.delete!(a)

      reloaded = Repo.reload!(child)
      assert reloaded.target_inherited_from_id == nil
      assert reloaded.target_branch == "exp/flows"
    end
  end
end
