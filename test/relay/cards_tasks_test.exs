defmodule Relay.CardsTasksTest do
  use Relay.DataCase, async: true

  import Ecto.Query

  alias Relay.Cards
  alias Relay.Events
  alias Schemas.Card
  alias Schemas.NodeExecution
  alias Schemas.SubTask

  setup do
    board = insert(:board, key: "RLY")
    stage = insert(:stage, board: board, position: 1)
    card = insert(:card, stage: stage)
    %{board: board, stage: stage, card: card}
  end

  defp rows(card), do: Repo.all(from st in SubTask, where: st.card_id == ^card.id, order_by: st.position)

  defp add!(card, titles) do
    {:ok, tasks} = Cards.add_tasks(card, Enum.map(titles, &%{"title" => &1, "body" => "body of " <> &1}))
    tasks
  end

  describe "add_tasks/2" do
    test "appends at 0.. on an empty card, in argument order, with bodies", %{card: card} do
      {:ok, [a, b]} = Cards.add_tasks(card, [%{"title" => "A", "body" => "alpha"}, %{"title" => "B"}])

      assert {a.title, a.position, a.body, a.done} == {"A", 0, "alpha", false}
      assert {b.title, b.position, b.body} == {"B", 1, nil}
      assert Enum.map(rows(card), & &1.id) == [a.id, b.id]
    end

    test "appends after existing tasks and leaves their ids and done untouched", %{card: card} do
      {:ok, card} = Cards.set_sub_tasks(card, [%{"title" => "a"}, %{"title" => "b", "done" => true}])
      [a, b] = card.sub_tasks

      {:ok, [first, second]} = Cards.add_tasks(card, [%{title: "First"}, %{title: "Second"}])

      assert {first.position, second.position} == {2, 3}

      assert [
               %SubTask{title: "a", done: false, position: 0} = a2,
               %SubTask{title: "b", done: true, position: 1} = b2,
               %SubTask{title: "First"},
               %SubTask{title: "Second"}
             ] = rows(card)

      assert {a2.id, b2.id} == {a.id, b.id}
    end

    test "is atomic: a blank title anywhere in the batch inserts nothing", %{card: card} do
      add!(card, ["keep"])

      assert {:error, %Ecto.Changeset{}} =
               Cards.add_tasks(card, [%{"title" => "ok"}, %{"title" => "ok2"}, %{"title" => ""}])

      assert Enum.map(rows(card), & &1.title) == ["keep"]
    end

    test "an empty batch is an error, not a no-op", %{card: card} do
      assert {:error, :empty} = Cards.add_tasks(card, [])
    end

    test "cannot set done or position through the attrs", %{card: card} do
      {:ok, [t]} = Cards.add_tasks(card, [%{"title" => "T", "done" => true, "position" => 9}])
      assert {t.done, t.position} == {false, 0}
    end

    test "broadcasts {:card_upserted, card} with the new task preloaded", %{board: board, card: card} do
      :ok = Events.subscribe(board.id)
      card_id = card.id

      {:ok, _} = Cards.add_tasks(card, [%{"title" => "T"}])

      assert_receive {:card_upserted, %Card{id: ^card_id, sub_tasks: [%SubTask{title: "T"}]}}
    end
  end

  describe "list_tasks/1 and get_task/2" do
    test "list is position-ordered; get returns the row with its body", %{card: card} do
      [a, b] = add!(card, ["A", "B"])

      assert Enum.map(Cards.list_tasks(card), & &1.id) == [a.id, b.id]
      assert {:ok, %SubTask{id: id, body: "body of B"}} = Cards.get_task(card, b.id)
      assert id == b.id
    end

    test "a task id from another card is :not_found", %{stage: stage, card: card} do
      other = insert(:card, stage: stage)
      [x] = add!(other, ["X"])

      assert {:error, :not_found} = Cards.get_task(card, x.id)
      assert {:error, :not_found} = Cards.get_task(card, 999_999_999)
    end
  end

  describe "task_count/1" do
    test "counts the card's tasks and nobody else's (RE357)", %{stage: stage, card: card} do
      other = insert(:card, stage: stage)
      assert Cards.task_count(card) == 0

      {:ok, _} = Cards.add_tasks(card, [%{title: "A"}, %{title: "B"}])
      {:ok, _} = Cards.add_tasks(other, [%{title: "C"}])

      assert Cards.task_count(card) == 2
    end
  end

  describe "update_task/3" do
    test "changes only title/body on that one row and cannot flip done or move it", %{card: card} do
      [a, b] = add!(card, ["A", "B"])
      {:ok, _} = Cards.set_sub_task_done(card, a.id, true)

      {:ok, updated} =
        Cards.update_task(card, b.id, %{"title" => "B2", "body" => "new", "done" => true, "position" => 0})

      assert {updated.id, updated.title, updated.body, updated.done, updated.position} ==
               {b.id, "B2", "new", false, 1}

      assert [%SubTask{title: "A", body: "body of A", done: true} = a2, %SubTask{id: b_id}] = rows(card)
      assert {a2.id, b_id} == {a.id, b.id}
    end

    test "a title-only update keeps the body", %{card: card} do
      [a] = add!(card, ["A"])
      {:ok, updated} = Cards.update_task(card, a.id, %{title: "A2"})
      assert {updated.title, updated.body} == {"A2", "body of A"}
    end

    test "a blank title is a changeset error and writes nothing", %{card: card} do
      [a] = add!(card, ["A"])
      assert {:error, %Ecto.Changeset{}} = Cards.update_task(card, a.id, %{"title" => ""})
      assert [%SubTask{title: "A"}] = rows(card)
    end

    test "a foreign or unknown id is :not_found", %{stage: stage, card: card} do
      [x] = add!(insert(:card, stage: stage), ["X"])
      assert {:error, :not_found} = Cards.update_task(card, x.id, %{"title" => "hijack"})
      assert Repo.get!(SubTask, x.id).title == "X"
    end

    test "broadcasts {:card_upserted, card}", %{board: board, card: card} do
      [a] = add!(card, ["A"])
      :ok = Events.subscribe(board.id)
      card_id = card.id

      {:ok, _} = Cards.update_task(card, a.id, %{"title" => "A2"})

      assert_receive {:card_upserted, %Card{id: ^card_id, sub_tasks: [%SubTask{title: "A2"}]}}
    end
  end

  describe "delete_task/2" do
    test "deletes the row, returns it, and closes the position gap", %{card: card} do
      [a, b, c] = add!(card, ["A", "B", "C"])
      {:ok, _} = Cards.set_sub_task_done(card, c.id, true)

      assert {:ok, %SubTask{id: deleted_id, title: "B", position: 1}} = Cards.delete_task(card, b.id)
      assert deleted_id == b.id

      assert [
               %SubTask{title: "A", body: "body of A", done: false, position: 0} = a2,
               %SubTask{title: "C", body: "body of C", done: true, position: 1} = c2
             ] = rows(card)

      assert {a2.id, c2.id} == {a.id, c.id}
    end

    test "a foreign or unknown id is :not_found and deletes nothing", %{stage: stage, card: card} do
      [x] = add!(insert(:card, stage: stage), ["X"])
      assert {:error, :not_found} = Cards.delete_task(card, x.id)
      assert Repo.get(SubTask, x.id)
    end

    test "broadcasts {:card_upserted, card}", %{board: board, card: card} do
      [a] = add!(card, ["A"])
      :ok = Events.subscribe(board.id)
      card_id = card.id

      {:ok, _} = Cards.delete_task(card, a.id)

      assert_receive {:card_upserted, %Card{id: ^card_id, sub_tasks: []}}
    end
  end

  describe "node_executions.sub_task_id across per-task writes" do
    test "a surviving task keeps its bound executions through add/update/delete of others",
         %{card: card} do
      [a, b, c] = add!(card, ["A", "B", "C"])
      execution = insert(:node_execution, run: insert(:run, card: card), sub_task_id: b.id)

      {:ok, _} = Cards.add_tasks(card, [%{"title" => "D"}])
      {:ok, _} = Cards.update_task(card, a.id, %{"title" => "A2"})
      {:ok, _} = Cards.update_task(card, b.id, %{"body" => "b2"})
      {:ok, _} = Cards.delete_task(card, c.id)

      assert Repo.get!(NodeExecution, execution.id).sub_task_id == b.id
    end

    test "deleting the bound task nilifies the execution's sub_task_id", %{card: card} do
      [a] = add!(card, ["A"])
      execution = insert(:node_execution, run: insert(:run, card: card), sub_task_id: a.id)

      {:ok, _} = Cards.delete_task(card, a.id)

      assert Repo.get!(NodeExecution, execution.id).sub_task_id == nil
    end
  end
end
