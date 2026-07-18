defmodule Relay.CardsSubTasksTest do
  use Relay.DataCase, async: true

  import Ecto.Query

  alias Relay.Cards
  alias Relay.Events
  alias Schemas.Card
  alias Schemas.SubTask

  setup do
    board = insert(:board, key: "RLY")
    stage = insert(:stage, board: board, position: 1)
    card = insert(:card, stage: stage)
    %{board: board, stage: stage, card: card}
  end

  describe "set_sub_tasks/2" do
    test "replaces the list and assigns 0-based positions", %{card: card} do
      {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "One"}, %{"title" => "Two"}])

      assert Enum.map(card.sub_tasks, & &1.title) == ["One", "Two"]
      assert Enum.map(card.sub_tasks, & &1.position) == [0, 1]
      assert Enum.all?(card.sub_tasks, &(&1.done == false))
    end

    test "replace-all deletes the previous list", %{card: card} do
      {:ok, _} = Cards.set_sub_tasks(card, [%{"title" => "Old A"}, %{"title" => "Old B"}])
      {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "New"}])

      assert Enum.map(card.sub_tasks, & &1.title) == ["New"]
      assert Repo.aggregate(from(st in SubTask, where: st.card_id == ^card.id), :count) == 1
    end

    test "accepts a preset done flag", %{card: card} do
      {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "Done one", "done" => true}])
      assert [%SubTask{done: true}] = card.sub_tasks
    end

    test "a blank title rolls the whole write back", %{card: card} do
      {:ok, _} = Cards.set_sub_tasks(card, [%{"title" => "Keep"}])
      assert {:error, %Ecto.Changeset{}} = Cards.set_sub_tasks(card, [%{"title" => ""}])

      titles =
        Repo.all(from st in SubTask, where: st.card_id == ^card.id, order_by: st.position, select: st.title)

      assert titles == ["Keep"]
    end
  end

  describe "set_sub_task_done/3" do
    test "toggles the item and persists", %{card: card} do
      {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "A"}, %{"title" => "B"}])
      [a, _b] = card.sub_tasks

      {:ok, card} = Cards.set_sub_task_done(card, a.id, true)
      assert Enum.find(card.sub_tasks, &(&1.id == a.id)).done
      assert Repo.get!(SubTask, a.id).done

      {:ok, card} = Cards.set_sub_task_done(card, a.id, false)
      refute Enum.find(card.sub_tasks, &(&1.id == a.id)).done
      refute Repo.get!(SubTask, a.id).done
    end

    test "is scoped to the card — a foreign sub_task id is not found", %{card: card} do
      other = insert(:card, stage: insert(:stage))
      {:ok, other} = Cards.set_sub_tasks(other, [%{"title" => "Foreign"}])
      [foreign] = other.sub_tasks

      assert {:error, :not_found} = Cards.set_sub_task_done(card, foreign.id, true)
    end
  end

  describe "notify_upserted/1" do
    test "reloads the card (owners + sub_tasks preloaded) and broadcasts {:card_upserted, card}",
         %{board: board, card: card} do
      {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "A", "done" => true}])
      :ok = Events.subscribe(board.id)

      assert :ok = Cards.notify_upserted(card)

      card_id = card.id
      assert_receive {:card_upserted, %Card{id: ^card_id} = broadcast_card}
      assert [%SubTask{title: "A", done: true}] = broadcast_card.sub_tasks
    end
  end

  describe "sub_task_progress/1" do
    test "counts done and total from the preloaded list", %{card: card} do
      {:ok, card} =
        Cards.set_sub_tasks(card, [
          %{"title" => "A", "done" => true},
          %{"title" => "B"},
          %{"title" => "C"}
        ])

      assert Cards.sub_task_progress(card) == %{done: 1, total: 3}
    end

    test "an empty list is 0/0" do
      assert Cards.sub_task_progress(%{sub_tasks: []}) == %{done: 0, total: 0}
    end
  end

  describe "update_ai_result/2" do
    test "stores the blob and it round-trips", %{card: card} do
      blob = %{"summary" => "Did the thing", "changes" => ["a", "b"]}
      {:ok, card} = Cards.update_ai_result(card, blob)

      assert card.ai_result == blob
      assert Repo.get!(Card, card.id).ai_result == blob
    end
  end

  describe "broadcasts" do
    test "set_sub_task_done broadcasts {:card_upserted, card}", %{board: board, card: card} do
      {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "A"}])
      [a] = card.sub_tasks
      :ok = Events.subscribe(board.id)

      {:ok, _} = Cards.set_sub_task_done(card, a.id, true)

      card_id = card.id
      assert_receive {:card_upserted, %Card{id: ^card_id}}
    end
  end
end
